/*
 * SkillManager: Manages the discovery, lifecycle, and DSH native skills directory sync
 * for Swai Agent Skills on HarmonyOS NEXT.
 * Stores all SKILL.md bundles directly inside `${filesDir}/workspace/.dsh/skills/` so
 * @deepseek-ai/dsh-skill-filesystem and @deepseek-ai/dsh-tool-skill discover and hot-reload them automatically.
 */
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import { BridgeController } from '../../common/BridgeController';
import { Skill } from './types';
import { SkillParser } from './SkillParser';

const DOMAIN: number = 0x0001;
const TAG: string = 'SkillManager';
const LEGACY_SKILLS_DIR = '/data/local/tmp/skills';
const DEFAULT_DSH_SKILLS_DIR = '/data/storage/el2/base/haps/entry/files/workspace/.dsh/skills';

const BUILTIN_SKILL_NAMES: string[] = [
  'openharmony-diag',
  'hmos-app-control',
  'hmos-network-helper',
  'hmos-ui-automation',
  'wechat-ui-automation',
  'baoyu-post-to-wechat'
];

function escapeXml(str: string): string {
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export const DEFAULT_BUILTIN_SKILLS: Skill[] = [
  {
    name: 'openharmony-diag',
    description: 'OpenHarmony 设备与系统服务状态深度诊断技能。基于官方调测工具（hidumper, hilog, param, power-shell）排查系统状态、窗口图层、进程内存/CPU占用、系统属性与崩溃故障。',
    filePath: `${DEFAULT_DSH_SKILLS_DIR}/openharmony-diag/SKILL.md`,
    baseDir: `${DEFAULT_DSH_SKILLS_DIR}/openharmony-diag`,
    isBuiltin: true
  },
  {
    name: 'hmos-app-control',
    description: 'OpenHarmony 应用管理与能力自动化调度工具。基于官方 aa（Ability助手）与 bm（包管理器）实现应用安装/卸载、生命周期调度、包信息查询与多开分身支持。',
    filePath: `${DEFAULT_DSH_SKILLS_DIR}/hmos-app-control/SKILL.md`,
    baseDir: `${DEFAULT_DSH_SKILLS_DIR}/hmos-app-control`,
    isBuiltin: true
  },
  {
    name: 'hmos-network-helper',
    description: 'OpenHarmony 端侧网络请求、路由排查与 API 调试指南。核心规则：系统终端基于 toybox 没有安装 curl 或 wget，所有网络请求必须使用原生 fetch 工具。',
    filePath: `${DEFAULT_DSH_SKILLS_DIR}/hmos-network-helper/SKILL.md`,
    baseDir: `${DEFAULT_DSH_SKILLS_DIR}/hmos-network-helper`,
    isBuiltin: true
  },
  {
    name: 'hmos-ui-automation',
    description: '基于原生 ui 工具（dumpLayout @ref/id/pagePath、视觉锚点、ROI 裁剪 OCR、run_sequence）与 capture_screen 的 HarmonyOS NEXT 跨应用自动化操作技能；支持通过 ui_skill_save 沉淀新 UI 技能。',
    filePath: `${DEFAULT_DSH_SKILLS_DIR}/hmos-ui-automation/SKILL.md`,
    baseDir: `${DEFAULT_DSH_SKILLS_DIR}/hmos-ui-automation`,
    isBuiltin: true
  },
  {
    name: 'wechat-ui-automation',
    description: '面向 HarmonyOS NEXT 原生微信（com.tencent.wechat）的 UI 自动化操作技能：处理分身弹窗选择打开方式、搜索联系人、查看会话摘要、切换 微信/通讯录/发现/我 页面、发送消息及严格的风控/资金停手边界。',
    filePath: `${DEFAULT_DSH_SKILLS_DIR}/wechat-ui-automation/SKILL.md`,
    baseDir: `${DEFAULT_DSH_SKILLS_DIR}/wechat-ui-automation`,
    isBuiltin: true
  },
  {
    name: 'baoyu-post-to-wechat',
    description: '基于内置 ArkWeb 浏览器与 CDP 自动化协议的微信公众号（订阅号/服务号）文章排版与草稿自动发布技能。支持 Markdown 自动转为精美内联样式 HTML、智能填写标题/作者/摘要，并直接将文章保存到微信公众号草稿箱。使用触发词："发布公众号"、"post to wechat"、"微信公众号"、"公众号草稿"。',
    filePath: `${DEFAULT_DSH_SKILLS_DIR}/baoyu-post-to-wechat/SKILL.md`,
    baseDir: `${DEFAULT_DSH_SKILLS_DIR}/baoyu-post-to-wechat`,
    isBuiltin: true
  }
];

export class SkillManager {
  private static instance: SkillManager = new SkillManager();

  private context: common.Context | null = null;
  private skillsDir: string = DEFAULT_DSH_SKILLS_DIR;
  private skills: Skill[] = [...DEFAULT_BUILTIN_SKILLS];

  static getInstance(): SkillManager {
    return SkillManager.instance;
  }

  private ensureDirRecursive(dirPath: string): void {
    const clean = dirPath.replace(/\/+$/, '');
    if (!clean) {
      return;
    }
    const parts = clean.split('/').filter(p => p.length > 0);
    let current = clean.startsWith('/') ? '' : '.';
    for (let i = 0; i < parts.length; i++) {
      current = `${current}/${parts[i]}`;
      try {
        if (!fs.accessSync(current)) {
          fs.mkdirSync(current);
        }
      } catch (_e) {
        try {
          fs.mkdirSync(current);
        } catch (_e2) {
          // ignore if concurrently created
        }
      }
    }
  }

  private writeFileIfChanged(filePath: string, content: string): void {
    try {
      if (fs.accessSync(filePath)) {
        const existing = fs.readTextSync(filePath);
        if (existing === content) {
          return;
        }
      }
    } catch (_e) {
      // ignore and write fresh
    }
    const file = fs.openSync(filePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, content);
    } finally {
      fs.closeSync(file);
    }
  }

  private formatSkillMarkdown(name: string, description: string, markdownBody: string): string {
    const safeName = JSON.stringify(name);
    const safeDesc = JSON.stringify(description.trim().replace(/\s+/g, ' '));
    return `---
name: ${safeName}
description: ${safeDesc}
---

${markdownBody.trim()}
`;
  }

  async init(context: common.Context): Promise<void> {
    this.context = context;
    const filesDir = context.filesDir || '/data/storage/el2/base/haps/entry/files';
    // Store skills inside workspace/.dsh/skills so DSH's @deepseek-ai/dsh-skill-filesystem watches them natively
    this.skillsDir = `${filesDir}/workspace/.dsh/skills`;

    try {
      this.ensureDirRecursive(this.skillsDir);
      await this.ensureDefaultSkills();
      await this.migrateLegacyCustomSkills();
      await this.reloadSkills();
      hilog.info(DOMAIN, TAG, 'SkillManager initialized with %{public}d skills at %{public}s', this.skills.length, this.skillsDir);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'Failed to initialize SkillManager: %{public}s', JSON.stringify(err));
    }
  }

  private async migrateLegacyCustomSkills(): Promise<void> {
    try {
      const findRes = await BridgeController.getInstance().exec(
        `find '${LEGACY_SKILLS_DIR}' -maxdepth 2 -name 'SKILL.md' 2>/dev/null`,
        '',
        6
      );
      if (!findRes.ok || !findRes.output) {
        return;
      }
      const files = findRes.output.split('\n').map(l => l.trim()).filter(l => l.length > 0);
      for (let i = 0; i < files.length; i++) {
        const legacyPath = files[i];
        const parts = legacyPath.split('/');
        const folderName = parts.length >= 2 ? parts[parts.length - 2] : '';
        if (!folderName || BUILTIN_SKILL_NAMES.includes(folderName)) {
          continue;
        }
        const targetDir = `${this.skillsDir}/${folderName}`;
        const targetFile = `${targetDir}/SKILL.md`;
        try {
          if (fs.accessSync(targetFile)) {
            continue;
          }
        } catch (_e) {
          // continue migration
        }
        const catRes = await BridgeController.getInstance().exec(`cat '${legacyPath}'`, '', 5);
        if (catRes.ok && catRes.output && catRes.output.trim().length > 0) {
          this.ensureDirRecursive(targetDir);
          this.writeFileIfChanged(targetFile, catRes.output);
        }
      }
    } catch (_err) {
      // Best-effort migration only
    }
  }

  getSkills(): Skill[] {
    return [...this.skills];
  }

  getSkillsDirectory(): string {
    return this.skillsDir;
  }

  getSkillByName(name: string): Skill | undefined {
    return this.skills.find(s => s.name === name);
  }

  /**
   * Reloads skills from workspace/.dsh/skills via native @ohos.file.fs.
   */
  async reloadSkills(): Promise<void> {
    const loaded: Map<string, Skill> = new Map();
    for (const b of DEFAULT_BUILTIN_SKILLS) {
      loaded.set(b.name, {
        name: b.name,
        description: b.description,
        filePath: `${this.skillsDir}/${b.name}/SKILL.md`,
        baseDir: `${this.skillsDir}/${b.name}`,
        isBuiltin: true
      });
    }

    try {
      if (fs.accessSync(this.skillsDir)) {
        const entries = fs.listFileSync(this.skillsDir);
        for (let i = 0; i < entries.length; i++) {
          const entryName = entries[i];
          const baseDir = `${this.skillsDir}/${entryName}`;
          const filePath = `${baseDir}/SKILL.md`;
          try {
            if (!fs.accessSync(filePath)) {
              continue;
            }
            const content = fs.readTextSync(filePath);
            if (content && content.length > 0) {
              const isBuiltin = BUILTIN_SKILL_NAMES.includes(entryName);
              const skill = SkillParser.parse(content, filePath, baseDir, isBuiltin);
              if (skill) {
                loaded.set(skill.name, skill);
              }
            }
          } catch (_entryErr) {
            // Skip unreadable entry
          }
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Error scanning skills in %{public}s: %{public}s', this.skillsDir, JSON.stringify(e));
    }

    this.skills = Array.from(loaded.values());
  }

  /**
   * Formats the active visible skills into the official Pi <available_skills> XML format.
   * Injected dynamically into the legacy AgentSession System Prompt.
   */
  formatSkillsForPrompt(fileReadTool: 'read' | 'bash' = 'read'): string {
    const visibleSkills = this.skills.filter(s => !s.disableModelInvocation);
    if (visibleSkills.length === 0) {
      return '';
    }

    const lines: string[] = [
      '\n\nThe following skills provide specialized instructions for specific tasks.',
      fileReadTool === 'read'
        ? 'Use the read tool to load a skill\'s file when the task matches its description.'
        : 'Use bash to load a skill\'s file when the task matches its description.',
      'When a skill file references a relative path, resolve it against the skill directory (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.',
      '',
      '<available_skills>'
    ];

    for (const skill of visibleSkills) {
      lines.push('  <skill>');
      lines.push(`    <name>${escapeXml(skill.name)}</name>`);
      lines.push(`    <description>${escapeXml(skill.description)}</description>`);
      lines.push(`    <location>${escapeXml(skill.filePath)}</location>`);
      lines.push('  </skill>');
    }
    lines.push('</available_skills>');

    return lines.join('\n');
  }

  /**
   * Creates a new custom skill in workspace/.dsh/skills so DSH picks it up live.
   */
  async createSkill(name: string, description: string, markdownBody: string): Promise<boolean> {
    const sanitizedName = name.trim().toLowerCase().replace(/[^a-z0-9_-]/g, '-').replace(/^-+|-+$/g, '');
    if (!sanitizedName || !description.trim()) {
      return false;
    }

    const targetDir = `${this.skillsDir}/${sanitizedName}`;
    const targetFile = `${targetDir}/SKILL.md`;
    const fullContent = this.formatSkillMarkdown(sanitizedName, description, markdownBody);

    try {
      this.ensureDirRecursive(targetDir);
      this.writeFileIfChanged(targetFile, fullContent);
      await this.reloadSkills();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to create skill %{public}s: %{public}s', sanitizedName, JSON.stringify(e));
      return false;
    }
  }

  /**
   * Deletes a custom skill from workspace/.dsh/skills.
   */
  async deleteSkill(name: string): Promise<boolean> {
    const sanitizedName = name.trim();
    const targetDir = `${this.skillsDir}/${sanitizedName}`;
    try {
      if (fs.accessSync(targetDir)) {
        fs.rmdirSync(targetDir);
      }
      await this.reloadSkills();
      return true;
    } catch (e) {
      hilog.error(DOMAIN, TAG, 'Failed to delete skill %{public}s: %{public}s', sanitizedName, JSON.stringify(e));
      return false;
    }
  }

  /**
   * Ensures default high-value HarmonyOS NEXT & WeChat skills are installed in workspace/.dsh/skills.
   */
  async ensureDefaultSkills(): Promise<void> {
    // 1. openharmony-diag
    await this.installBuiltinSkill(
      'openharmony-diag',
      'OpenHarmony 设备与系统服务状态深度诊断技能。基于官方调测工具（hidumper, hilog, param, power-shell）排查系统状态、窗口图层、进程内存/CPU占用、系统属性与崩溃故障。',
      `# OpenHarmony 设备与服务状态诊断指南（官方调测规范）

当用户需要排查系统问题、崩溃、图层或资源占用时，请遵循以下标准流程：

## 1. 窗口与图层诊断 (hidumper)
\`\`\`bash
hidumper -l
hidumper -s WindowManagerService -a '-a' | head -n 60
hidumper -s RenderService -a "fps" 2>/dev/null || true
\`\`\`

## 2. 日志检索与实时诊断 (hilog)
- 必须使用 \`hilog -x\` 非阻塞模式，直接执行 \`hilog\` 会永久挂起：
\`\`\`bash
hilog -x -P <pid> | tail -n 50
hilog -x -T <tag> | tail -n 50
\`\`\`

## 3. 内存与进程资源诊断
- 进程内存：\`hidumper --mem <pid>\`
- 系统资源：\`top -b -n 1\` 或 \`hidumper --cpu\`
- 进程存活：\`pidof <bundleName>\`

## 4. 系统属性 (param) 与崩溃日志 (faultlog)
\`\`\`bash
param get const.product.model
param get const.build.version
ls -lt /data/log/faultlog/temp/ | head -n 15
\`\`\`
`
    );

    // 2. hmos-app-control
    await this.installBuiltinSkill(
      'hmos-app-control',
      'OpenHarmony 应用管理与能力自动化调度工具。基于官方 aa（Ability助手）与 bm（包管理器）实现应用安装/卸载、生命周期调度、包信息查询与多开分身支持。',
      `# OpenHarmony 应用包管理与调度指南（官方调测规范）

## 1. 包管理器 (bm) 与包名发现
- 切勿猜测 Android 包名（例如鸿蒙支付宝为 \`com.alipay.mobile.client\`，小红书为 \`com.xingin.xhs_hos\`，美团为 \`com.sankuai.hmeituan\`，淘宝为 \`com.taobao.taobao4hmos\`）。
- 推荐直接调用 \`ui(action="list_apps", contains_text="...")\` 或在 bash 执行：
\`\`\`bash
bm dump -a | grep -i <keyword>
bm dump -n <bundleName> | grep -o '"mainAbility":"[^"]\\+"' | head -n 1
\`\`\`

## 2. Ability 助手 (aa)
\`\`\`bash
# 启动应用主身（-u 100 优先指定主用户，若仍出现「选择打开方式」弹窗则用 ui 点击主实例）
aa start -a EntryAbility -b <bundleName> -u 100
# 强制停止应用
aa force-stop <bundleName>
\`\`\`
- 禁止使用 \`aa start -A ohos.want.action.viewData\` 打开外部浏览器访问网页，所有网页任务请用内置 \`browser_*\` 工具。
`
    );

    // 3. hmos-network-helper
    await this.installBuiltinSkill(
      'hmos-network-helper',
      'OpenHarmony 端侧网络请求、路由排查与 API 调试指南。核心规则：系统终端基于 toybox 没有安装 curl 或 wget，所有网络请求必须使用原生 fetch 工具。',
      `# OpenHarmony 网络请求与环境指南

## 1. 关键约束
- 设备终端没有 \`curl\` 或 \`wget\`，所有 HTTP/HTTPS 请求请调用原生 \`fetch\` 工具。

## 2. 网络状态排查
\`\`\`bash
ifconfig
netstat -rn
\`\`\`
`
    );

    // 4. hmos-ui-automation (rewritten around actual Swai ui + capture_screen + ui_skill_save stack)
    await this.installBuiltinSkill(
      'hmos-ui-automation',
      '基于原生 ui 工具（dumpLayout @ref/id/pagePath、视觉锚点、ROI 裁剪 OCR、run_sequence）与 capture_screen 的 HarmonyOS NEXT 跨应用自动化操作技能；支持通过 ui_skill_save 沉淀新 UI 技能。',
      `# HarmonyOS NEXT UI 自动化操作规范

## 入口
- 优先调用 \`ui(action="list_apps", contains_text="...")\` 确认目标应用的真实鸿蒙包名（\`bundleName\`）与 \`mainAbility\`，禁止凭经验猜测 Android 包名。
- 调用 \`ui(action="launch_app", bundle_name="...", ability_name="EntryAbility")\` 启动目标应用；多开分身应用若弹出系统「选择打开方式」底部面板，直接点击其中目标应用主项。

## 步骤
1. **读界面与判断页面**：先调用 \`ui(action="dump_tree", bundle_name="...")\`。重点查看返回头部：
   - \`App:\`（当前真实包名）
   - \`Page:\`（鸿蒙页面路由 \`pagePath\`，例如 \`pages/WechatAppPage\`、\`entry/RootPage\`）
   - \`TreeQuality:\`（\`full\` / \`sparse\` / \`empty\`）
   - 优先使用 \`@ref\`（如 \`ref: "@4"\`）或稳定的组件 \`id\` 进行 \`find_and_click\`，比纯文本更抗误触。
2. **鸿蒙特有图标与无标签容器处理**：
   - 鸿蒙界面大量顶部图标使用 \`SymbolGlyph\` 或 \`Image\`（无 \`text\`）；优先使用 \`ui(action="click_anchor", anchor="search"|"back"|"more"|"chat_input"|"voice_toggle"|"send")\`。
   - 对可点击复合容器，\`dump_tree\` 已自动聚合内部子文本到 \`desc\` 中。
3. **TreeQuality 降级策略（绝不盲目重复 dump_tree）**：
   - 若 \`TreeQuality\` 为 \`sparse\` 或 \`empty\`（自绘视图 / Canvas / 游戏 / 部分弹窗），\`dump_tree\` 会自动附带**按目标窗口 ROI 裁剪的 CoreVision OCR** 结果，直接依据 OCR 文字与中心坐标点击。
   - 若仍缺图标位置或需要整体视觉确认，调用 \`capture_screen\` 查看画面后用 \`ui(action="click_point", x=..., y=...)\`。
4. **文本输入与多步加速**：
   - 一律用 \`ui(action="input_text", ...)\`（底层走 \`uitest uiInput\` 支持中文，自动支持 \`clear_first\` 与 \`auto_send\`）；禁止用 \`uinput -K -t\` 输入中文，禁止用 \`read\` 读取截图文件。
   - 对确定的多步流程，用 \`ui(action="run_sequence", steps=[...])\` 在本地一次流水线执行完，大幅减少轮次耗时。
5. **沉淀可复用 UI 技能**：
   - 完成一次多步跨应用流程后，调用 \`ui_skill_save(mode="inspect_trace")\` 读取已脱敏的真实步骤（已自动抹除用户输入原文），再用 \`ui_skill_save(mode="save", ...)\` 沉淀为五段式技能保存到 \`.dsh/skills/\`。

## 容易出错的地方
- **分屏视角混淆**：\`launch_app\` 默认尝试上下分屏。所有带坐标的操作与 \`ocr\` 均已按当前目标窗口边界隔离，仍应核对 \`App:\` 是否已经切回目标应用（或从 \`com.ohos.sceneboard\` 弹窗进入）。
- **NO_EFFECT 不得连点**：工具返回 \`[ACTION EFFECT]: NO_EFFECT\` 时，严禁重复点击完全相同的坐标；应重新 \`dump_tree\` 检查 \`@ref\` / 窗口变化，或改用 \`click_anchor\` / \`ocr\` / \`swipe\`。
- **风控节奏 Apps**：对标记 \`pace=careful\` 的应用（如微信 \`com.tencent.wechat\`、小红书 \`com.xingin.xhs_hos\`、支付宝 \`com.alipay.mobile.client\`），宿主会自动插入 \`450-850ms\` 随机节流；不要并发高频点击或高速翻页。

## 怎样算办成（核实证据）
- 每步均核对动作后返回的 \`App:\`、\`Page:\` 与 \`[Post-Action Screen State]\` 中的真实控件或文本变化，禁止仅凭“点击返回成功”宣布任务完成。
- 目标结果必须在页面元素文本或 \`capture_screen\` 画面中可见（例如提示词出现、列表出现新条目、页面切换至目标 \`pagePath\`）。

## 什么时候停下交给用户
- 涉及付款、转账、红包、下单结算、删除重要数据、更改账号密码或实名信息；
- 出现登录扫码、短信/图形验证码、安全键盘或防截屏黑屏保护页（\`TreeQuality: empty\` 且截图/OCR 均为空白）；
- 用户未明确授权对外发送消息/公开发布内容前的最终确认。
`
    );

    // 5. wechat-ui-automation (calibrated against live HarmonyOS NEXT device layout inspection)
    await this.installBuiltinSkill(
      'wechat-ui-automation',
      '面向 HarmonyOS NEXT 原生微信（com.tencent.wechat）的 UI 自动化操作技能：处理分身弹窗选择打开方式、搜索联系人、查看会话摘要、切换 微信/通讯录/发现/我 页面、发送消息及严格的风控/资金停手边界。',
      `# 微信 (HarmonyOS NEXT) UI 自动化操作技能

## 入口
- 包名：\`com.tencent.wechat\`，入口 Ability：\`EntryAbility\`（主框架实测 \`pagePath: pages/WechatAppPage\`）。
- 启动命令：\`ui(action="launch_app", bundle_name="com.tencent.wechat", ability_name="EntryAbility")\`（默认自动处理分身弹窗并点击第 1 个主「微信」）。
- **多开分身默认策略**：若手机装有多个微信（「微信」与「微信1」），系统可能弹出底部「选择打开方式」面板：
  - \`launch_app\` 默认（\`clone_index=0\`）会自动点击**第 1 个「微信」**直接进入主微信，无需停下询问用户；
  - 仅当用户明确要求“用微信1/小号/分身”时传 \`clone_index=1\`；
  - 若在后续界面看到该面板且尚未自动关闭，直接点击第 1 个 \`text="微信"\` 项（\`index=0\`）即可。

## 步骤
### 场景 A：切换底部主标签（微信 / 通讯录 / 发现 / 我）
1. 在 \`pages/WechatAppPage\` 上查看底部标签文本节点（实测底部 \`Text\` 标签为 \`微信\`、\`通讯录\`、\`发现\`、\`我\`），或查看顶部导航标题 \`id="WeTopNavigationBarCenterTitle_..."\` 判断当前所在标签页。
2. 调用 \`ui(action="find_and_click", bundle_name="com.tencent.wechat", text="<目标标签名>")\` 切换。

### 场景 B：搜索联系人 / 群聊并查看或发送消息
1. 若目标会话在当前列表不可见，调用 \`ui(action="click_anchor", bundle_name="com.tencent.wechat", anchor="search")\` 点击右上角放大镜（实测微信顶部搜索/加号多为无文本 \`SymbolGlyph\`/\`Image\` 图标）。
2. 调用 \`ui(action="input_text", bundle_name="com.tencent.wechat", content="<联系人或群名>", clear_first=true)\` 输入检索词。
3. 在搜索结果中用 \`dump_tree(bundle_name="com.tencent.wechat")\` 查看结果项，优先使用 \`@ref\` 点击**列表结果项**（而非输入框本身）；若列表文字缺失，改用 \`ui(action="ocr", bundle_name="com.tencent.wechat")\` 按 OCR 行坐标点击。
4. 进入会话后，先核对顶部导航栏标题（\`WeTopNavigationBarCenterTitle_...\`）确认为目标联系人/群名：
   - **只读汇总**：读取列表可见文本 / OCR 文字，必要时适度 \`swipe(direction="down"|"up")\` 翻看；注意 \`pace=careful\` 不要高速连刷。
   - **发送消息（须在用户明确要求发给谁和发什么之后）**：先点击 \`click_anchor(anchor="chat_input")\`（若页面显示「按住 说话」，先点 \`click_anchor(anchor="voice_toggle")\` 切回键盘）；再调用 \`input_text(content="<消息正文>", auto_send=false)\`，**先确认草稿无误、再确认是否已获发送授权**，然后点击 \`发送\`（或 \`auto_send=true\`）。

### 场景 C：进入朋友圈或小程序
- 点击底部 \`发现\` → 点击 \`朋友圈\`（右上角相机按钮通常为无文字 \`SymbolGlyph\`/\`Image\`）；小程序入口优先通过顶部搜索框搜索进入。

## 容易出错的地方
- **只看文字会漏掉大量图标**：实测鸿蒙微信主框架约 170+ 节点中仅有约 13 个带 \`clickable=true\`、大量图标使用 \`SymbolGlyph\` 与嵌套 \`Stack\`/\`Row\`/\`Column\`；优先借助聚合描述、\`@ref\` 与 \`click_anchor\`。
- **输入框为 \`RichEditor\`**：未聚焦前在常规 \`TextInput\` 筛选里可能不显示，使用 \`anchor="chat_input"\` 或 \`input_text\` 自动识别。
- **搜索结果防误点输入框**：搜索词与结果联系人名字相同，务必选择列表项（\`@ref\` 或非输入框节点），避免点回顶部搜索框。
- **分身识别**：如遇「选择打开方式」弹窗，默认选第 1 个主微信（无角标），勿点带 \`iconMark\` 的分身项（除非用户明确要求）。
- **防风控节流（\`pace=careful\`）**：\`UiTool\` 对 \`com.tencent.wechat\` 已启用 \`450-850ms\` 自动动作节流；长列表浏览时适度停顿。

## 怎样算办成（核实证据）
- 切换页面：顶部标题 \`WeTopNavigationBarCenterTitle_...\`（或页面 \`pagePath\`）已变为目标名称。
- 发送消息：底部输入框已清空（不再残留待发草稿），且消息区顶部/最新可见文本或 OCR 中已出现本次发出的消息内容。
- 汇总/查询：向用户陈述的内容全部来自实际读取到的节点文本、OCR 结果或 \`capture_screen\` 观察到的内容，未猜测未展示的消息。

## 什么时候停下交给用户
- 任何**微信支付、发红包、转账、收款确认**页面；
- **首次向外部联系人/群发送重要、不可撤回或敏感内容前**（若用户仅要求“起草”或目标联系人名称存在多个相似候选如同名好友/群，必须停下确认）；
- 遇到登录扫码、滑块风控验证、账号安全提示、或密码/验证弹窗。
`
    );

    // 6. baoyu-post-to-wechat
    await this.installBuiltinSkill(
      'baoyu-post-to-wechat',
      '基于内置 ArkWeb 浏览器与 CDP 自动化协议的微信公众号（订阅号/服务号）文章排版与草稿自动发布技能。支持 Markdown 自动转为精美内联样式 HTML、智能填写标题/作者/摘要，并直接将文章保存到微信公众号草稿箱。使用触发词："发布公众号"、"post to wechat"、"微信公众号"、"公众号草稿"。',
      `# 微信公众号文章排版与草稿发布指南（ArkWeb CDP 自动化版）

当用户需要撰写文章并发布到微信公众号（订阅号/服务号）草稿箱时，请遵循以下流程：

## 1. 核心发布工具：\`wechat_render_article\` & \`wechat_post_draft\`
优先使用 DSH 工具 \`wechat_post_draft\`（或旧会话 \`browser(action="wechat_publish")\`）完成端侧自动化排版与草稿保存：
- **严禁使用 bash 执行 \`aa start -A ohos.want.action.viewData\` 打开外置浏览器**；所有网页交互与草稿保存均由内置 ArkWeb CDP 完成。
- 如果公众号未登录，提示用户在内置「浏览器」视图中微信扫码登录一次，Cookie 会话会自动持久化。
`
    );
  }

  private async installBuiltinSkill(name: string, description: string, body: string): Promise<void> {
    const targetDir = `${this.skillsDir}/${name}`;
    const targetFile = `${targetDir}/SKILL.md`;
    const fullContent = this.formatSkillMarkdown(name, description, body);

    try {
      this.ensureDirRecursive(targetDir);
      this.writeFileIfChanged(targetFile, fullContent);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'Failed to install builtin skill %{public}s: %{public}s', name, JSON.stringify(e));
    }
  }
}
