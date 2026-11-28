/*
 * Pure ArkTS parser, filter, and formatter for HarmonyOS `uitest dumpLayout` JSON trees.
 * Kept isolated from native OS imports so layout parsing and matching can be unit-tested cleanly.
 */

export interface UiBounds {
  left: number;
  top: number;
  right: number;
  bottom: number;
  width: number;
  height: number;
  cx: number;
  cy: number;
  raw: string;
}

export interface UiWindowInfo {
  hostWindowId: string;
  bundleName: string;
  abilityName: string;
  pagePath: string;
  focused: boolean;
  bounds: UiBounds;
  nodeCount: number;
  interactiveCount: number;
}

export interface UiNode {
  index: number;
  text: string;
  hint: string;
  description: string;
  id: string;
  type: string;
  bundleName: string;
  abilityName: string;
  pagePath: string;
  hostWindowId: string;
  bounds: UiBounds;
  clickable: boolean;
  scrollable: boolean;
  enabled: boolean;
  visible: boolean;
  focused: boolean;
  selected: boolean;
  checked: boolean;
  longClickable: boolean;
  depth: number;
}

export interface UiNodeQuery {
  ref?: string | number;
  text?: string;
  containsText?: string;
  id?: string;
  nodeType?: string;
  clickableOnly?: boolean;
  scrollableOnly?: boolean;
}

export interface UiTreeParseResult {
  nodes: UiNode[];
  windows: UiWindowInfo[];
  activeBundle: string;
  activePagePath: string;
  activeWindowBounds?: UiBounds;
  overlayExcludeBounds?: UiBounds[];
  treeQuality: 'full' | 'sparse' | 'empty';
  totalVisited: number;
  screenWidth: number;
  screenHeight: number;
}

export class UiLayoutParser {
  static parseBounds(boundsText: string): UiBounds | null {
    if (!boundsText || typeof boundsText !== 'string') {
      return null;
    }
    const m = boundsText.match(/\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\]\s*\[\s*(-?\d+)\s*,\s*(-?\d+)\s*\]/);
    if (!m) {
      return null;
    }
    const left = parseInt(m[1], 10);
    const top = parseInt(m[2], 10);
    const right = parseInt(m[3], 10);
    const bottom = parseInt(m[4], 10);
    const width = right - left;
    const height = bottom - top;
    if (!Number.isFinite(left) || !Number.isFinite(top) || width <= 0 || height <= 0) {
      return null;
    }
    return {
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      cx: Math.round((left + right) / 2),
      cy: Math.round((top + bottom) / 2),
      raw: `[${left},${top}][${right},${bottom}]`
    };
  }

  private static readBool(attrs: Record<string, Object>, key: string, defaultVal: boolean): boolean {
    const val = attrs[key];
    if (typeof val === 'boolean') {
      return val;
    }
    if (typeof val === 'string') {
      const lower = val.trim().toLowerCase();
      if (lower === 'true' || lower === '1') {
        return true;
      }
      if (lower === 'false' || lower === '0') {
        return false;
      }
    }
    return defaultVal;
  }

  private static readStr(attrs: Record<string, Object>, key: string): string {
    const val = attrs[key];
    if (typeof val === 'string') {
      return val;
    }
    return '';
  }

  private static computeTreeQuality(nodes: UiNode[]): 'full' | 'sparse' | 'empty' {
    if (nodes.length === 0) {
      return 'empty';
    }
    let labeledOrInteractive = 0;
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i];
      if (n.text.length > 0 || n.hint.length > 0 || n.description.length > 0 || n.clickable || n.scrollable) {
        labeledOrInteractive++;
      }
    }
    if (labeledOrInteractive === 0) {
      return 'empty';
    }
    if (labeledOrInteractive < 3) {
      return 'sparse';
    }
    return 'full';
  }

  private static computeBoundingBox(nodes: UiNode[]): UiBounds | undefined {
    if (nodes.length === 0) {
      return undefined;
    }
    let left = nodes[0].bounds.left;
    let top = nodes[0].bounds.top;
    let right = nodes[0].bounds.right;
    let bottom = nodes[0].bounds.bottom;
    for (let i = 1; i < nodes.length; i++) {
      const b = nodes[i].bounds;
      if (b.left < left) left = b.left;
      if (b.top < top) top = b.top;
      if (b.right > right) right = b.right;
      if (b.bottom > bottom) bottom = b.bottom;
    }
    const width = right - left;
    const height = bottom - top;
    if (width <= 0 || height <= 0) {
      return undefined;
    }
    return {
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      cx: Math.round((left + right) / 2),
      cy: Math.round((top + bottom) / 2),
      raw: `[${left},${top}][${right},${bottom}]`
    };
  }

  static extractTree(rawJson: string, includeUninteractive: boolean = false): UiTreeParseResult {
    const trimmed = (rawJson ?? '').trim();
    if (trimmed.length === 0) {
      throw new Error('Layout JSON output is empty');
    }
    const parsed = JSON.parse(trimmed) as Object;
    const nodes: UiNode[] = [];
    const windowMap: Map<string, UiWindowInfo> = new Map();
    let totalVisited = 0;
    let screenWidth = 0;
    let screenHeight = 0;

    const visit = (
      item: Object,
      depth: number,
      inheritedBundle: string,
      inheritedAbility: string,
      inheritedPagePath: string,
      inheritedWinId: string,
      inheritedFocused: boolean
    ): string[] => {
      if (!item || typeof item !== 'object') {
        return [];
      }
      totalVisited++;
      const obj = item as Record<string, Object>;
      const rawAttrs = obj['attributes'];
      const attrs: Record<string, Object> =
        (rawAttrs && typeof rawAttrs === 'object' && !Array.isArray(rawAttrs))
          ? (rawAttrs as Record<string, Object>)
          : obj;

      const rawBundle = (UiLayoutParser.readStr(attrs, 'bundleName') || UiLayoutParser.readStr(obj, 'bundleName')).trim();
      const rawAbility = (UiLayoutParser.readStr(attrs, 'abilityName') || UiLayoutParser.readStr(obj, 'abilityName')).trim();
      const rawPagePath = (UiLayoutParser.readStr(attrs, 'pagePath') || UiLayoutParser.readStr(obj, 'pagePath')).trim();
      const rawWinId = (UiLayoutParser.readStr(attrs, 'hostWindowId') || UiLayoutParser.readStr(obj, 'hostWindowId')).trim();

      const currentBundle = rawBundle.length > 0 ? rawBundle : inheritedBundle;
      const currentAbility = rawAbility.length > 0 ? rawAbility : (rawBundle.length > 0 && rawBundle !== inheritedBundle ? '' : inheritedAbility);
      const currentPagePath = rawPagePath.length > 0 ? rawPagePath : (rawBundle.length > 0 && rawBundle !== inheritedBundle ? '' : inheritedPagePath);
      const currentWinId = rawWinId.length > 0 ? rawWinId : inheritedWinId;

      const focused = UiLayoutParser.readBool(attrs, 'focused', false);
      const windowFocused = focused || inheritedFocused;

      const boundsStr = UiLayoutParser.readStr(attrs, 'bounds') || UiLayoutParser.readStr(obj, 'bounds');
      const bounds = UiLayoutParser.parseBounds(boundsStr);

      let pushedNode: UiNode | null = null;
      const ownLabels: string[] = [];

      if (bounds !== null) {
        if (bounds.right > screenWidth) {
          screenWidth = bounds.right;
        }
        if (bounds.bottom > screenHeight) {
          screenHeight = bounds.bottom;
        }
        const visible = UiLayoutParser.readBool(attrs, 'visible', true);
        const enabled = UiLayoutParser.readBool(attrs, 'enabled', true);
        const clickable = UiLayoutParser.readBool(attrs, 'clickable', false);
        const scrollable = UiLayoutParser.readBool(attrs, 'scrollable', false);
        const selected = UiLayoutParser.readBool(attrs, 'selected', false);
        const checked = UiLayoutParser.readBool(attrs, 'checked', false);
        const longClickable = UiLayoutParser.readBool(attrs, 'longClickable', false);
        const text = UiLayoutParser.readStr(attrs, 'text').trim();
        const hint = UiLayoutParser.readStr(attrs, 'hint').trim();
        const description = (UiLayoutParser.readStr(attrs, 'description') ||
          UiLayoutParser.readStr(attrs, 'accessibilityText')).trim();
        const id = UiLayoutParser.readStr(attrs, 'id').trim();
        const nodeType = (UiLayoutParser.readStr(attrs, 'type') || 'Component').trim();

        if (currentBundle.length > 0 && visible) {
          const winKey = `${currentWinId}|${currentBundle}`;
          let winInfo = windowMap.get(winKey);
          if (!winInfo) {
            winInfo = {
              hostWindowId: currentWinId,
              bundleName: currentBundle,
              abilityName: currentAbility,
              pagePath: currentPagePath,
              focused: windowFocused,
              bounds: bounds,
              nodeCount: 0,
              interactiveCount: 0
            };
            windowMap.set(winKey, winInfo);
          } else {
            if (winInfo.abilityName.length === 0 && currentAbility.length > 0) {
              winInfo.abilityName = currentAbility;
            }
            if (winInfo.pagePath.length === 0 && currentPagePath.length > 0) {
              winInfo.pagePath = currentPagePath;
            }
            if (focused) {
              winInfo.focused = true;
            }
            if (bounds.width * bounds.height > winInfo.bounds.width * winInfo.bounds.height) {
              winInfo.bounds = bounds;
            }
          }
          winInfo.nodeCount++;
          if (clickable || scrollable || text.length > 0 || description.length > 0) {
            winInfo.interactiveCount++;
          }
        }

        const primaryLabel = text.length > 0 ? text : (description.length > 0 ? description : hint);
        if (primaryLabel.length > 0) {
          ownLabels.push(primaryLabel);
        }

        const hasMeaningfulLabel = text.length > 0 || hint.length > 0 || description.length > 0 || id.length > 0;
        if (visible && (includeUninteractive || clickable || scrollable || hasMeaningfulLabel)) {
          pushedNode = {
            index: nodes.length,
            text: text,
            hint: hint,
            description: description,
            id: id,
            type: nodeType,
            bundleName: currentBundle,
            abilityName: currentAbility,
            pagePath: currentPagePath,
            hostWindowId: currentWinId,
            bounds: bounds,
            clickable: clickable,
            scrollable: scrollable,
            enabled: enabled,
            visible: visible,
            focused: focused,
            selected: selected,
            checked: checked,
            longClickable: longClickable,
            depth: depth
          };
          nodes.push(pushedNode);
        }
      }

      const descendantLabels: string[] = [];
      const rawChildren = obj['children'];
      if (Array.isArray(rawChildren)) {
        for (let i = 0; i < rawChildren.length; i++) {
          const childLabels = visit(
            rawChildren[i] as Object,
            depth + 1,
            currentBundle,
            currentAbility,
            currentPagePath,
            currentWinId,
            windowFocused
          );
          for (let j = 0; j < childLabels.length && descendantLabels.length < 6; j++) {
            const lbl = childLabels[j];
            if (lbl.length > 0 && !descendantLabels.includes(lbl)) {
              descendantLabels.push(lbl);
            }
          }
        }
      }

      // Container semantic aggregation: synthesize searchable description on unlabeled clickable containers
      if (pushedNode !== null && pushedNode.clickable &&
        pushedNode.text.length === 0 && pushedNode.description.length === 0 && pushedNode.hint.length === 0 &&
        descendantLabels.length > 0) {
        const joined = descendantLabels.slice(0, 3).join(' | ');
        pushedNode.description = joined.length > 60 ? joined.substring(0, 57) + '...' : joined;
      }

      return ownLabels.length > 0 ? ownLabels : descendantLabels;
    };

    if (Array.isArray(parsed)) {
      const list = parsed as Object[];
      for (let i = 0; i < list.length; i++) {
        visit(list[i], 0, '', '', '', '', false);
      }
    } else {
      visit(parsed, 0, '', '', '', '', false);
    }

    const windows = Array.from(windowMap.values());
    const finalW = screenWidth > 0 ? screenWidth : 1080;
    const finalH = screenHeight > 0 ? screenHeight : 2400;
    const baseResult: UiTreeParseResult = {
      nodes: nodes,
      windows: windows,
      activeBundle: '',
      activePagePath: '',
      activeWindowBounds: undefined,
      treeQuality: UiLayoutParser.computeTreeQuality(nodes),
      totalVisited: totalVisited,
      screenWidth: finalW,
      screenHeight: finalH
    };
    return UiLayoutParser.populateActiveWindowMeta(baseResult);
  }

  private static extractOverlayExcludeBounds(windows: UiWindowInfo[], activeBundle: string): UiBounds[] {
    if (activeBundle === 'com.shuwei.shellbridge' || activeBundle.length === 0) {
      return [];
    }
    const excludes: UiBounds[] = [];
    for (let i = 0; i < windows.length; i++) {
      const w = windows[i];
      if (w.bundleName === 'com.shuwei.shellbridge' && w.bounds.width > 0 && w.bounds.height > 0) {
        excludes.push(w.bounds);
      }
    }
    return excludes;
  }

  private static populateActiveWindowMeta(tree: UiTreeParseResult): UiTreeParseResult {
    let activeBundle = '';
    let activePagePath = '';
    let activeWindowBounds: UiBounds | undefined = undefined;

    for (let i = 0; i < tree.windows.length; i++) {
      const w = tree.windows[i];
      if (w.bundleName !== 'com.shuwei.shellbridge' && w.bundleName !== 'com.ohos.sceneboard') {
        if (!activeWindowBounds || w.focused || w.interactiveCount > 0) {
          activeBundle = w.bundleName;
          activePagePath = w.pagePath;
          activeWindowBounds = w.bounds;
          if (w.focused) {
            break;
          }
        }
      }
    }

    if (activeBundle.length === 0 && tree.nodes.length > 0) {
      for (let i = 0; i < tree.nodes.length; i++) {
        if (tree.nodes[i].bundleName.length > 0) {
          activeBundle = tree.nodes[i].bundleName;
          activePagePath = tree.nodes[i].pagePath;
          break;
        }
      }
      activeWindowBounds = UiLayoutParser.computeBoundingBox(tree.nodes);
    }

    return {
      nodes: tree.nodes,
      windows: tree.windows,
      activeBundle: activeBundle,
      activePagePath: activePagePath,
      activeWindowBounds: activeWindowBounds,
      overlayExcludeBounds: UiLayoutParser.extractOverlayExcludeBounds(tree.windows, activeBundle),
      treeQuality: UiLayoutParser.computeTreeQuality(tree.nodes),
      totalVisited: tree.totalVisited,
      screenWidth: tree.screenWidth,
      screenHeight: tree.screenHeight
    };
  }

  private static isStatusBarWindow(w: UiWindowInfo): boolean {
    return w.bundleName === 'com.ohos.sceneboard' && (w.bounds.height <= 200 || w.bounds.bottom <= 220);
  }

  private static selectSceneboardSheetWindow(windows: UiWindowInfo[]): UiWindowInfo | undefined {
    const sheets = windows.filter(w =>
      w.bundleName === 'com.ohos.sceneboard' && !UiLayoutParser.isStatusBarWindow(w)
    );
    if (sheets.length === 0) {
      return undefined;
    }
    const sorted = sheets.slice().sort((a, b) => {
      if (a.focused !== b.focused) {
        return a.focused ? -1 : 1;
      }
      if (a.bounds.height !== b.bounds.height) {
        return b.bounds.height - a.bounds.height;
      }
      return b.interactiveCount - a.interactiveCount;
    });
    return sorted[0];
  }

  static filterToTargetWindow(tree: UiTreeParseResult, bundleName?: string): UiTreeParseResult {
    const requested = (bundleName ?? '').trim();
    if (requested.length > 0) {
      if (requested === 'com.ohos.sceneboard' || requested.toLowerCase().includes('sceneboard')) {
        const sheetWin = UiLayoutParser.selectSceneboardSheetWindow(tree.windows);
        if (sheetWin) {
          const sheetNodes = tree.nodes.filter(n =>
            n.bundleName === sheetWin.bundleName &&
            (sheetWin.hostWindowId.length === 0 || n.hostWindowId === sheetWin.hostWindowId)
          );
          if (sheetNodes.length > 0) {
            return {
              nodes: sheetNodes,
              windows: tree.windows,
              activeBundle: sheetWin.bundleName,
              activePagePath: sheetWin.pagePath,
              activeWindowBounds: sheetWin.bounds,
              treeQuality: UiLayoutParser.computeTreeQuality(sheetNodes),
              totalVisited: tree.totalVisited,
              screenWidth: tree.screenWidth,
              screenHeight: tree.screenHeight
            };
          }
        }
      } else {
        const filtered = tree.nodes.filter(n => n.bundleName === requested || n.bundleName.includes(requested));
        if (filtered.length > 0) {
          let matchedPage = '';
          for (let i = 0; i < filtered.length; i++) {
            if (filtered[i].pagePath.length > 0) {
              matchedPage = filtered[i].pagePath;
              break;
            }
          }
          const winMatch = tree.windows.find(w => w.bundleName === requested || w.bundleName.includes(requested));
          return {
            nodes: filtered,
            windows: tree.windows,
            activeBundle: filtered[0].bundleName,
            activePagePath: matchedPage.length > 0 ? matchedPage : (winMatch ? winMatch.pagePath : ''),
            activeWindowBounds: winMatch ? winMatch.bounds : UiLayoutParser.computeBoundingBox(filtered),
            overlayExcludeBounds: UiLayoutParser.extractOverlayExcludeBounds(tree.windows, filtered[0].bundleName),
            treeQuality: UiLayoutParser.computeTreeQuality(filtered),
            totalVisited: tree.totalVisited,
            screenWidth: tree.screenWidth,
            screenHeight: tree.screenHeight
          };
        }
      }
      // Fall through: requested bundle might have triggered a system sheet (e.g. sceneboard clone selector "选择打开方式")
    }

    // Isolate target app window when multiple split/system windows exist
    const nonSystemWindows = tree.windows.filter(w =>
      w.bundleName !== 'com.shuwei.shellbridge' && w.bundleName !== 'com.ohos.sceneboard'
    );
    let targetWin: UiWindowInfo | undefined = undefined;
    if (nonSystemWindows.length > 0) {
      targetWin = nonSystemWindows.find(w => w.focused) ||
        nonSystemWindows.slice().sort((a, b) => b.interactiveCount - a.interactiveCount)[0];
    } else if (tree.windows.length > 0) {
      targetWin = UiLayoutParser.selectSceneboardSheetWindow(tree.windows);
    }

    if (targetWin) {
      const winNodes = tree.nodes.filter(n =>
        n.bundleName === targetWin!.bundleName &&
        (targetWin!.bundleName !== 'com.ohos.sceneboard' ||
          targetWin!.hostWindowId.length === 0 ||
          n.hostWindowId === targetWin!.hostWindowId)
      );
      if (winNodes.length > 0) {
        return {
          nodes: winNodes,
          windows: tree.windows,
          activeBundle: targetWin.bundleName,
          activePagePath: targetWin.pagePath,
          activeWindowBounds: targetWin.bounds,
          overlayExcludeBounds: UiLayoutParser.extractOverlayExcludeBounds(tree.windows, targetWin.bundleName),
          treeQuality: UiLayoutParser.computeTreeQuality(winNodes),
          totalVisited: tree.totalVisited,
          screenWidth: tree.screenWidth,
          screenHeight: tree.screenHeight
        };
      }
    }

    return UiLayoutParser.populateActiveWindowMeta(tree);
  }

  private static labelMatchesExact(node: UiNode, targetLower: string): boolean {
    return node.text.toLowerCase() === targetLower ||
      node.hint.toLowerCase() === targetLower ||
      node.description.toLowerCase() === targetLower;
  }

  private static labelContains(node: UiNode, needleLower: string): boolean {
    return node.text.toLowerCase().includes(needleLower) ||
      node.hint.toLowerCase().includes(needleLower) ||
      node.description.toLowerCase().includes(needleLower);
  }

  static filterNodes(nodes: UiNode[], query: UiNodeQuery): UiNode[] {
    // Direct ref matching (@N or N) takes highest precedence
    if (query.ref !== undefined && query.ref !== null) {
      const rawRef = String(query.ref).trim().replace(/^@/, '');
      const refIndex = parseInt(rawRef, 10);
      if (Number.isFinite(refIndex)) {
        const direct = nodes.filter((n: UiNode) => n.index === refIndex);
        if (direct.length > 0) {
          return direct;
        }
      }
    }

    const exactText = (query.text ?? '').trim().toLowerCase();
    const containsText = (query.containsText ?? '').trim().toLowerCase();
    const targetId = (query.id ?? '').trim().toLowerCase();
    const targetType = (query.nodeType ?? '').trim().toLowerCase();

    const candidates = nodes.filter((node: UiNode) => {
      if (query.clickableOnly === true && !node.clickable) {
        return false;
      }
      if (query.scrollableOnly === true && !node.scrollable) {
        return false;
      }
      if (targetId.length > 0 && !node.id.toLowerCase().includes(targetId)) {
        return false;
      }
      if (targetType.length > 0 && !node.type.toLowerCase().includes(targetType)) {
        return false;
      }
      if (exactText.length > 0 && !UiLayoutParser.labelContains(node, exactText)) {
        return false;
      }
      if (containsText.length > 0 &&
        !UiLayoutParser.labelContains(node, containsText) &&
        !node.id.toLowerCase().includes(containsText)) {
        return false;
      }
      return true;
    });

    // Rank best interactive & exact matches first
    candidates.sort((a: UiNode, b: UiNode) => {
      const scoreNode = (n: UiNode): number => {
        let score = 0;
        if (exactText.length > 0 && UiLayoutParser.labelMatchesExact(n, exactText)) {
          score += 100;
        }
        if (targetId.length > 0 && n.id.toLowerCase() === targetId) {
          score += 80;
        }
        if (n.enabled) {
          score += 20;
        }
        if (n.clickable) {
          score += 15;
        }
        return score;
      };
      const diff = scoreNode(b) - scoreNode(a);
      if (diff !== 0) {
        return diff;
      }
      return a.index - b.index;
    });

    return candidates;
  }

  static formatNodeLine(node: UiNode): string {
    const parts: string[] = [`@${node.index}`, `[${node.type}]`];
    if (node.text.length > 0) {
      parts.push(`text="${node.text}"`);
    }
    if (node.hint.length > 0) {
      parts.push(`hint="${node.hint}"`);
    }
    if (node.description.length > 0) {
      parts.push(`desc="${node.description}"`);
    }
    if (node.id.length > 0) {
      parts.push(`id="${node.id}"`);
    }
    parts.push(`center=(${node.bounds.cx},${node.bounds.cy})`);
    parts.push(`bounds=${node.bounds.raw}`);
    const flags: string[] = [];
    if (node.clickable) {
      flags.push('clickable');
    }
    if (node.longClickable) {
      flags.push('longClickable');
    }
    if (node.scrollable) {
      flags.push('scrollable');
    }
    if (node.focused) {
      flags.push('focused');
    }
    if (node.selected) {
      flags.push('selected');
    }
    if (node.checked) {
      flags.push('checked');
    }
    if (!node.enabled) {
      flags.push('disabled');
    }
    if (flags.length > 0) {
      parts.push(flags.join(','));
    }
    return parts.join(' ');
  }

  static formatSummary(tree: UiTreeParseResult, filtered: UiNode[], maxItems: number = 100): string {
    const appLabel = tree.activeBundle || 'unknown';
    const pageLabel = tree.activePagePath || 'unknown';
    const qualityLabel = tree.treeQuality || 'full';
    const lines: string[] = [
      `Screen: ${tree.screenWidth}x${tree.screenHeight} | App: ${appLabel} | Page: ${pageLabel} | TreeQuality: ${qualityLabel} | Matched: ${filtered.length}/${tree.totalVisited}`
    ];
    if (tree.windows && tree.windows.length > 1) {
      const winParts: string[] = [];
      for (let i = 0; i < tree.windows.length; i++) {
        const w = tree.windows[i];
        winParts.push(`${w.bundleName}${w.pagePath ? `(${w.pagePath})` : ''} ${w.bounds.raw}`);
      }
      lines.push(`Windows: ${winParts.join(' ; ')}`);
    }
    if (filtered.length === 0) {
      lines.push('(No matching visible UI nodes found)');
      return lines.join('\n');
    }
    const cap = Math.min(filtered.length, Math.max(1, maxItems));
    for (let i = 0; i < cap; i++) {
      lines.push(UiLayoutParser.formatNodeLine(filtered[i]));
    }
    if (filtered.length > cap) {
      lines.push(`... (+${filtered.length - cap} more nodes truncated; refine with text/contains_text/id/clickable_only)`);
    }
    return lines.join('\n');
  }
}
