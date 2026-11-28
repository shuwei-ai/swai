/*
 * AppKnowledgeBase provides structured application knowledge profiles for popular HarmonyOS NEXT apps.
 * Calibrated from live HarmonyOS NEXT device inspection and Mika's APP.md architecture.
 * Contains verified HarmonyOS bundle names, entry abilities, pagePath cues, UI structure quirks,
 * risk pacing metadata, and parameterized run_sequence recipes.
 */

export interface RecipeStep {
  op: string;
  bundle_name?: string;
  anchor?: string;
  text?: string;
  auto_send?: boolean;
  target?: string;
}

export interface AppProfile {
  bundleName: string;
  displayName: string;
  mainAbility: string;
  pace: 'normal' | 'careful';
  aliases: string[];
  description: string;
  knownPages: Record<string, string>;
  uiQuirks: string[];
  fastRecipes: Record<string, RecipeStep[]>;
}

const WECHAT_SEND_RECIPE: RecipeStep[] = [
  { op: 'launch', bundle_name: 'com.tencent.wechat' },
  { op: 'click_anchor', anchor: 'search' },
  { op: 'type', text: '{CONTACT}', auto_send: false },
  { op: 'tap', target: '{CONTACT}' },
  { op: 'click_anchor', anchor: 'chat_input' },
  { op: 'type', text: '{MESSAGE}', auto_send: true }
];

const WECHAT_SWITCH_TAB_RECIPE: RecipeStep[] = [
  { op: 'launch', bundle_name: 'com.tencent.wechat' },
  { op: 'tap', target: '{TAB_NAME}' }
];

const NOTEPAD_CREATE_RECIPE: RecipeStep[] = [
  { op: 'launch', bundle_name: 'com.huawei.hmos.notepad' },
  { op: 'tap', target: '新建笔记' },
  { op: 'type', text: '{CONTENT}' }
];

const SETTINGS_SEARCH_RECIPE: RecipeStep[] = [
  { op: 'launch', bundle_name: 'com.huawei.hmos.settings' },
  { op: 'click_anchor', anchor: 'search' },
  { op: 'type', text: '{SETTING_KEYWORD}', auto_send: false }
];

export class AppKnowledgeBase {
  private static getWechatProfile(): AppProfile {
    const recipes: Record<string, RecipeStep[]> = {
      'send_message': WECHAT_SEND_RECIPE,
      'switch_tab': WECHAT_SWITCH_TAB_RECIPE
    };
    const pages: Record<string, string> = {
      'pages/WechatAppPage': '微信主框架（包含 微信/通讯录/发现/我 底部四标签与顶部标题栏 WeTopNavigationBarCenterTitle）'
    };
    return {
      bundleName: 'com.tencent.wechat',
      displayName: '微信 (HarmonyOS NEXT)',
      mainAbility: 'EntryAbility',
      pace: 'careful',
      aliases: ['微信', 'wechat', 'wx'],
      description: '腾讯微信 HarmonyOS NEXT 原生版。主要结构为 微信 / 通讯录 / 发现 / 我 四个标签页。',
      knownPages: pages,
      uiQuirks: [
        '【应用分身弹窗】当手机开启微信分身（微信 / 微信1）并弹出「选择打开方式」时，launch_app 默认会自动点击第 1 项（clone_index=0 即主微信）；仅当用户明确要求打开“微信1/分身”时传 clone_index=1。若在后续界面意外见到该弹窗，直接点击第 1 项 Row（text="微信", index=0）即可，不要因此停下询问。',
        '【顶部图标与搜索】顶部导航栏标题文本在 id="WeTopNavigationBarCenterTitle_..." 中；右上角搜索放大镜与“+”多为 SymbolGlyph/Image 无文本节点，用 click_anchor(anchor="search") 或坐标盲区匹配。',
        '【聊天输入框与语音态】聊天输入框通常为 RichEditor，未聚焦前在纯 TextInput 过滤中可能不可见；若出现「按住 说话」，先点 click_anchor(anchor="voice_toggle") 切回键盘再输入；输入时可用 input_text(..., auto_send=true) 一步发送。',
        '【自绘/无标签列表】部分会话/消息区域若出现 TreeQuality: sparse/empty 或缺少文字标签，立即切换 ui(action="ocr")（已自动裁剪微信窗口区域）或 capture_screen。',
        '【搜索防误触】搜索结果页点击联系人时优先用 @ref 或明确 target，避免误点回顶部搜索框本身。'
      ],
      fastRecipes: recipes
    };
  }

  private static getXhsProfile(): AppProfile {
    return {
      bundleName: 'com.xingin.xhs_hos',
      displayName: '小红书 (HarmonyOS NEXT)',
      mainAbility: 'EntryAbility',
      pace: 'careful',
      aliases: ['小红书', 'xhs', 'xiaohongshu'],
      description: '小红书鸿蒙原生版，包含发现/关注/购物/消息/我与图文笔记搜索流。',
      knownPages: {},
      uiQuirks: [
        '【风控节流】高频翻页或连续点开详情易触发滑动验证码，操作需留有停顿，遇验证界面立即交由用户处理。',
        '【搜索与双列卡片】首页顶部搜索入口与笔记卡片多为复合可点击容器，优先按 @ref、文本或 OCR 定位标题后点击。'
      ],
      fastRecipes: {}
    };
  }

  private static getFeishuProfile(): AppProfile {
    const pages: Record<string, string> = {
      'entry/RootPage': '飞书主界面'
    };
    return {
      bundleName: 'com.ss.feishu',
      displayName: '飞书 (HarmonyOS NEXT)',
      mainAbility: 'EntryAbility',
      pace: 'normal',
      aliases: ['飞书', 'feishu', 'lark'],
      description: '飞书鸿蒙原生版，约 40%+ 界面控件带有显式 id 与大量 SymbolGlyph/Stack 复合布局。',
      knownPages: pages,
      uiQuirks: [
        '【高密度 id 树】飞书大量图标使用 SymbolGlyph 且带有稳定 component id，优先通过 @ref 或 id 匹配；无文本的复合 Row/Stack 容器依赖语义聚合描述。'
      ],
      fastRecipes: {}
    };
  }

  private static getAlipayProfile(): AppProfile {
    return {
      bundleName: 'com.alipay.mobile.client',
      displayName: '支付宝 (HarmonyOS NEXT)',
      mainAbility: 'EntryAbility',
      pace: 'careful',
      aliases: ['支付宝', 'alipay'],
      description: '蚂蚁支付宝鸿蒙原生版（注意真机包名为 com.alipay.mobile.client）。',
      knownPages: {},
      uiQuirks: [
        '【支付/隐私安全】涉及付款码、转账确认、余额密码页可能开启防截屏或安全键盘，遇到此类页面必须立即停下交由用户亲自操作。',
        '【顶部功能区与搜索】顶部搜索框直达小程序/生活服务最快，尽量避免在首页金刚区盲目滑动。'
      ],
      fastRecipes: {}
    };
  }

  private static getNotepadProfile(): AppProfile {
    const recipes: Record<string, RecipeStep[]> = {
      'create_note': NOTEPAD_CREATE_RECIPE
    };
    return {
      bundleName: 'com.huawei.hmos.notepad',
      displayName: '华为备忘录',
      mainAbility: 'EntryAbility',
      pace: 'normal',
      aliases: ['备忘录', '便签', 'notepad', 'notes'],
      description: '华为系统备忘录应用，用于记录笔记与待办。',
      knownPages: {},
      uiQuirks: [
        '【新建笔记】主界面底部有新建笔记悬浮按钮；进入编辑页后顶部为标题栏，下方为正文输入框。',
        '【保存退出】编辑完成后点击右上角确认勾选图标或发送 back 按键保存。'
      ],
      fastRecipes: recipes
    };
  }

  private static getSettingsProfile(): AppProfile {
    const recipes: Record<string, RecipeStep[]> = {
      'search_setting': SETTINGS_SEARCH_RECIPE
    };
    return {
      bundleName: 'com.huawei.hmos.settings',
      displayName: '系统设置',
      mainAbility: 'EntryAbility',
      pace: 'normal',
      aliases: ['设置', '系统设置', 'settings'],
      description: 'HarmonyOS NEXT 系统设置。',
      knownPages: {},
      uiQuirks: [
        '【顶部搜索】查找 Wi-Fi、蓝牙、应用管理等设置项优先使用顶部搜索栏直达，减少盲目长滚动。'
      ],
      fastRecipes: recipes
    };
  }

  private static getMeituanProfile(): AppProfile {
    return {
      bundleName: 'com.sankuai.hmeituan',
      displayName: '美团 (HarmonyOS NEXT)',
      mainAbility: 'EntryAbility',
      pace: 'careful',
      aliases: ['美团', 'meituan'],
      description: '美团鸿蒙原生版，覆盖外卖、团购与到店服务。',
      knownPages: {},
      uiQuirks: [
        '【外卖区分与下单确认】注意首页频道入口与底部标签的跳转差异；进入结算/支付页前必须停下由用户确认金额与下单。'
      ],
      fastRecipes: {}
    };
  }

  private static getTaobaoProfile(): AppProfile {
    return {
      bundleName: 'com.taobao.taobao4hmos',
      displayName: '淘宝 (HarmonyOS NEXT)',
      mainAbility: 'EntryAbility',
      pace: 'careful',
      aliases: ['淘宝', 'taobao'],
      description: '淘宝鸿蒙原生版（注意真机包名为 com.taobao.taobao4hmos）。',
      knownPages: {},
      uiQuirks: [
        '【下单止损边界】支持搜索、筛选与加购，禁止自动提交结算付款；高频翻页注意防风控。'
      ],
      fastRecipes: {}
    };
  }

  private static getAllProfiles(): AppProfile[] {
    return [
      AppKnowledgeBase.getWechatProfile(),
      AppKnowledgeBase.getXhsProfile(),
      AppKnowledgeBase.getFeishuProfile(),
      AppKnowledgeBase.getAlipayProfile(),
      AppKnowledgeBase.getNotepadProfile(),
      AppKnowledgeBase.getSettingsProfile(),
      AppKnowledgeBase.getMeituanProfile(),
      AppKnowledgeBase.getTaobaoProfile()
    ];
  }

  /**
   * Finds the best matching app profile given a bundle name or user query string.
   */
  static findProfile(query: string): AppProfile | null {
    if (!query) {
      return null;
    }
    const q = query.trim().toLowerCase();
    const profiles = AppKnowledgeBase.getAllProfiles();

    for (let i = 0; i < profiles.length; i++) {
      const p = profiles[i];
      if (p.bundleName.toLowerCase() === q) {
        return p;
      }
      for (let j = 0; j < p.aliases.length; j++) {
        if (q.includes(p.aliases[j].toLowerCase())) {
          return p;
        }
      }
    }

    return null;
  }

  static isCarefulApp(bundleName?: string): boolean {
    if (!bundleName || bundleName.trim().length === 0) {
      return false;
    }
    const profile = AppKnowledgeBase.findProfile(bundleName);
    return profile !== null && profile.pace === 'careful';
  }

  static formatCompactHint(profile: AppProfile): string {
    const lines: string[] = [
      `[App Knowledge: ${profile.displayName} (${profile.bundleName}) | pace=${profile.pace}]`
    ];
    const pageKeys = Object.keys(profile.knownPages);
    if (pageKeys.length > 0) {
      const pageDesc = pageKeys.map(k => `${k}=${profile.knownPages[k]}`).join('; ');
      lines.push(`- 已知页面: ${pageDesc}`);
    }
    for (let i = 0; i < profile.uiQuirks.length; i++) {
      lines.push(`- ${profile.uiQuirks[i]}`);
    }
    const recipeNames = Object.keys(profile.fastRecipes);
    if (recipeNames.length > 0) {
      lines.push(`- 常用 fastRecipes: ${recipeNames.join(', ')}`);
    }
    return lines.join('\n');
  }

  /**
   * Formats application knowledge guidance to be injected into agent / worker prompts.
   */
  static getKnowledgePrompt(bundleOrQuery?: string): string {
    if (bundleOrQuery) {
      const match = AppKnowledgeBase.findProfile(bundleOrQuery);
      if (match) {
        return AppKnowledgeBase.formatProfile(match);
      }
    }

    const profiles = AppKnowledgeBase.getAllProfiles();
    const sections: string[] = ['### 📱 高频应用专属认知库 (App Knowledge Base)'];
    for (let i = 0; i < profiles.length; i++) {
      sections.push(AppKnowledgeBase.formatProfile(profiles[i]));
    }
    return sections.join('\n\n');
  }

  private static formatProfile(profile: AppProfile): string {
    const lines: string[] = [
      `#### 📦 应用: ${profile.displayName} (\`${profile.bundleName}\`, ability=\`${profile.mainAbility}\`, pace=\`${profile.pace}\`)`,
      `- **说明**: ${profile.description}`,
      `- **界面特征与避坑要点**:`
    ];
    for (let i = 0; i < profile.uiQuirks.length; i++) {
      lines.push(`  * ${profile.uiQuirks[i]}`);
    }

    const recipeNames = Object.keys(profile.fastRecipes);
    if (recipeNames.length > 0) {
      lines.push(`- **推荐极速连续操作流水线 (run_sequence Recipes)**:`);
      for (let i = 0; i < recipeNames.length; i++) {
        const recipe = profile.fastRecipes[recipeNames[i]];
        lines.push(`  * \`${recipeNames[i]}\`:\n\`\`\`json\n${JSON.stringify(recipe, null, 2)}\n\`\`\``);
      }
    }
    return lines.join('\n');
  }
}
