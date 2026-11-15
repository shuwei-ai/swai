/*
 * BrowserPipState: Manages the floating Picture-in-Picture (Pip) state,
 * bookmark sites, recent browsing history, and attention glow effects.
 *
 * Inspired by Mika's AgentPip architecture.
 * SPDX-License-Identifier: Apache-2.0
 */

export enum PipMode {
  HIDDEN = 'hidden',
  MINI = 'mini',
  EXPANDED = 'expanded'
}

export enum PipGlowStatus {
  NORMAL = 'normal',
  RUNNING = 'running',     // Green glow during autonomous agent operation
  ATTENTION = 'attention'  // Breathing orange glow when user intervention is required (e.g. captcha/login)
}

export interface FavoriteSiteItem {
  id: string;
  title: string;
  url: string;
  iconBgColor: string;
  iconText: string;
}

export interface RecentPageItem {
  id: string;
  title: string;
  url: string;
  timeLabel: string;
  timestamp: number;
}

export class BrowserPipState {
  private static instance: BrowserPipState | null = null;

  public mode: PipMode = PipMode.HIDDEN;
  public glowStatus: PipGlowStatus = PipGlowStatus.NORMAL;
  public posX: number = -1; // -1 means auto-dock to bottom right
  public posY: number = -1;

  // Preset favorite sites (matching reference Mika user screenshot)
  public favoriteSites: FavoriteSiteItem[] = [
    {
      id: 'wechat_mp',
      title: '微信公众平台',
      url: 'https://mp.weixin.qq.com',
      iconBgColor: '#07c160',
      iconText: '微'
    },
    {
      id: 'harmony_dev',
      title: '开发者联盟',
      url: 'https://developer.huawei.com',
      iconBgColor: '#0284c7',
      iconText: '鸿'
    },
    {
      id: 'github',
      title: 'GitHub',
      url: 'https://github.com',
      iconBgColor: '#181717',
      iconText: 'Git'
    },
    {
      id: 'bing',
      title: '必应搜索',
      url: 'https://cn.bing.com',
      iconBgColor: '#008373',
      iconText: 'Bing'
    }
  ];

  // Browsing history
  public recentPages: RecentPageItem[] = [
    {
      id: 'recent_1',
      title: '微信公众平台',
      url: 'https://mp.weixin.qq.com',
      timeLabel: '刚刚',
      timestamp: Date.now()
    },
    {
      id: 'recent_2',
      title: 'HarmonyOS NEXT 开发者文档',
      url: 'https://developer.huawei.com',
      timeLabel: '昨天',
      timestamp: Date.now() - 86400000
    }
  ];

  private listeners: Array<() => void> = [];

  public static getInstance(): BrowserPipState {
    if (!BrowserPipState.instance) {
      BrowserPipState.instance = new BrowserPipState();
    }
    return BrowserPipState.instance;
  }

  public subscribe(listener: () => void): () => void {
    this.listeners.push(listener);
    return () => {
      this.listeners = this.listeners.filter(l => l !== listener);
    };
  }

  private notify(): void {
    for (const l of this.listeners) {
      try {
        l();
      } catch (_e) {}
    }
  }

  public showMini(): void {
    this.mode = PipMode.MINI;
    this.notify();
  }

  public showExpanded(): void {
    this.mode = PipMode.EXPANDED;
    this.notify();
  }

  public hide(): void {
    this.mode = PipMode.HIDDEN;
    this.notify();
  }

  public toggle(): void {
    if (this.mode === PipMode.HIDDEN) {
      this.mode = PipMode.MINI;
    } else if (this.mode === PipMode.MINI) {
      this.mode = PipMode.EXPANDED;
    } else {
      this.mode = PipMode.MINI;
    }
    this.notify();
  }

  public setGlow(status: PipGlowStatus): void {
    this.glowStatus = status;
    this.notify();
  }

  public addRecentPage(title: string, url: string): void {
    const existingIndex = this.recentPages.findIndex(p => p.url === url);
    if (existingIndex >= 0) {
      this.recentPages.splice(existingIndex, 1);
    }
    this.recentPages.unshift({
      id: `recent_${Date.now()}`,
      title: title && title.length > 0 ? title : url,
      url: url,
      timeLabel: '刚刚',
      timestamp: Date.now()
    });
    if (this.recentPages.length > 20) {
      this.recentPages.pop();
    }
    this.notify();
  }

  public clearRecentPages(): void {
    this.recentPages = [];
    this.notify();
  }
}
