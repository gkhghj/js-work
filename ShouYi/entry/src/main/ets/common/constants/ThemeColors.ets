import { ThemeStore } from '../theme/ThemeStore';

/**
 * 界面配色与尺寸。
 *
 * 视觉定位：安全、可信、克制。
 * 主色用深蓝（传达可靠），辅助色用青绿（健康），危险色用砖红（告警）。
 *
 * ==================== 三模式改造说明 ====================
 *
 * 原来这些是 `static readonly` 常量。为了支持日间/夜间切换，改成
 * **静态 getter**：调用点仍然写 `AppColor.BG`，但每次取到的值会跟随
 * ThemeStore 的当前主题变化。全工程几百处调用一行都不用改。
 *
 * 三个新增语义色，解决"同一个常量被当两种用途"的问题：
 *   ON_PRIMARY  —— 铺在主色/危险色实心块上的文字（恒为白）
 *   ACCENT      —— 页面底色上的强调文字与图标（夜间要提亮，否则糊在深底上）
 *   HEADER_BG   —— 顶部深色标题栏背景（夜间保持深沉，不跟着 ACCENT 变亮）
 *
 * 关怀模式不影响颜色，只影响字号与信息密度（见 AppSize）。
 */
export class AppColor {

  // ==================== 品牌与语义色 ====================

  /**
   * 主色 · 实心块填充（按钮底、选中态、等级标签）。
   * 夜间提亮到中蓝：既保证白字压得住，又不会在深底上糊成一块黑。
   */
  static get PRIMARY(): string {
    return ThemeStore.isNight() ? '#3A6FB0' : '#1F3A5F';
  }

  /** 强调色 · 页面底色上的文字/图标/折线。夜间必须比 PRIMARY 更亮 */
  static get ACCENT(): string {
    return ThemeStore.isNight() ? '#8CB8EE' : '#1F3A5F';
  }

  /** 顶部标题栏背景。夜间保持深沉，避免整屏过亮 */
  static get HEADER_BG(): string {
    return ThemeStore.isNight() ? '#16243A' : '#1F3A5F';
  }

  /** 铺在 PRIMARY / DANGER 等实心块上的文字色。两种主题下都是白 */
  static get ON_PRIMARY(): string {
    return '#FFFFFF';
  }

  /** 辅助色 · 青绿（健康） */
  static get SECONDARY(): string {
    return ThemeStore.isNight() ? '#4FBFA5' : '#2E7D6B';
  }

  /** 危险色 · 砖红 */
  static get DANGER(): string {
    return ThemeStore.isNight() ? '#EF5B5B' : '#C62828';
  }

  /** 警示色 · 琥珀 */
  static get WARNING(): string {
    return ThemeStore.isNight() ? '#F0A93B' : '#E08A00';
  }

  /** 正常色 · 绿 */
  static get SUCCESS(): string {
    return ThemeStore.isNight() ? '#4CC46A' : '#2E7D32';
  }

  /**
   * 协同角色色 · 浅蓝。
   * 只用于家庭成员里的社区网格员 / 物业值班标签 —— 他们是"外部协同方"，
   * 权限上与直系家属不同（看不到活动报告），用浅蓝让家属一眼分辨。
   */
  static get INFO(): string {
    return ThemeStore.isNight() ? '#7FB2DE' : '#5B93C4';
  }

  // ==================== 中性色 ====================

  /** 页面底色 */
  static get BG(): string {
    return ThemeStore.isNight() ? '#0E141B' : '#F5F6F8';
  }

  /** 卡片底 */
  static get CARD(): string {
    return ThemeStore.isNight() ? '#18202B' : '#FFFFFF';
  }

  /** 主文本 */
  static get TEXT(): string {
    return ThemeStore.isNight() ? '#E8EDF3' : '#1A1D21';
  }

  /** 次文本 */
  static get TEXT_2(): string {
    return ThemeStore.isNight() ? 'rgba(232,237,243,0.66)' : 'rgba(26,29,33,0.66)';
  }

  /** 弱文本 */
  static get TEXT_3(): string {
    return ThemeStore.isNight() ? 'rgba(232,237,243,0.42)' : 'rgba(26,29,33,0.45)';
  }

  /** 分割线 */
  static get LINE(): string {
    return ThemeStore.isNight() ? 'rgba(255,255,255,0.10)' : 'rgba(26,29,33,0.12)';
  }

  /** 浅底（未选中态、次级按钮底） */
  static get SURFACE(): string {
    return ThemeStore.isNight() ? 'rgba(255,255,255,0.06)' : 'rgba(26,29,33,0.04)';
  }

  // ==================== 告警等级 ====================

  /**
   * 告警等级色。
   *
   * 严重度阶梯：P0 红 → P1 橙黄 → P2 绿 → P3 灰。
   * 红 = 紧急高危（燃气/烟雾/SOS）；橙黄 = 高风险；绿 = 正常/需关注；灰 = 提示。
   * 家属在任何一页看到颜色，含义都一样，不需要在脑子里做映射。
   *
   * P2 曾是黄色、现为绿色：绿色=需关注、橙黄=高风险，两档必须分开，
   * 否则投屏上几乎分不出等级差。
   */
  static levelColor(level: string): string {
    switch (level) {
      case 'P0':
        return AppColor.DANGER;
      case 'P1':
        return AppColor.WARNING;
      case 'P2':
        return AppColor.SUCCESS;
      default:
        return AppColor.TEXT_3;
    }
  }

  /** 告警等级浅底。夜间提高不透明度，否则深底上看不出色块 */
  static levelBg(level: string): string {
    const night: boolean = ThemeStore.isNight();
    switch (level) {
      case 'P0':
        return night ? 'rgba(239,91,91,0.16)' : 'rgba(198,40,40,0.06)';
      case 'P1':
        return night ? 'rgba(240,169,59,0.16)' : 'rgba(224,138,0,0.08)';
      case 'P2':
        return night ? 'rgba(76,196,106,0.16)' : 'rgba(46,125,50,0.08)';
      default:
        return AppColor.SURFACE;
    }
  }

  // ==================== 传感器状态 ====================

  /** 传感器状态 → 圆点颜色（三色体系 + 离线灰） */
  static statusColor(status: string): string {
    switch (status) {
      case 'normal':
        return AppColor.SUCCESS;
      case 'warning':
        return AppColor.WARNING;
      case 'danger':
        return AppColor.DANGER;
      default:
        return AppColor.TEXT_3;
    }
  }

  /** 传感器状态 → 卡片描边色。正常与离线都用中性分割线，避免整屏花掉 */
  static statusBorder(status: string): string {
    switch (status) {
      case 'warning':
        return ThemeStore.isNight() ? 'rgba(240,169,59,0.45)' : 'rgba(224,138,0,0.45)';
      case 'danger':
        return AppColor.DANGER;
      default:
        return AppColor.LINE;
    }
  }

  /** 传感器状态 → 图标与数值文字色。常态主文本，只有异常才着色 */
  static statusTextColor(status: string): string {
    switch (status) {
      case 'normal':
        return AppColor.TEXT;
      case 'warning':
        return AppColor.WARNING;
      case 'danger':
        return AppColor.DANGER;
      default:
        return AppColor.TEXT_3;
    }
  }

  /** 传感器状态 → 图标色。常态次文本保持页面低调，异常才跟随状态色 */
  static statusIconColor(status: string): string {
    switch (status) {
      case 'normal':
        return AppColor.TEXT_2;
      case 'warning':
        return AppColor.WARNING;
      case 'danger':
        return AppColor.DANGER;
      default:
        return AppColor.TEXT_3;
    }
  }

  // ==================== 智能研判分级 ====================

  /**
   * 三档：正常（绿）/ 关注（浅橙）/ 异常告警（红）。
   * 「关注」刻意不用红：夜间活动偏多、活动量波动属于"建议留意"，不是"危险"。
   * 把提示也刷成红，整页就没有信息层级，家属很快对红色脱敏。
   */
  static readonly INSIGHT_NORMAL: string = 'normal';
  static readonly INSIGHT_ATTENTION: string = 'attention';
  static readonly INSIGHT_DANGER: string = 'danger';

  /** 研判分级 → 标签底色 */
  static insightBg(level: string): string {
    const night: boolean = ThemeStore.isNight();
    switch (level) {
      case AppColor.INSIGHT_ATTENTION:
        return night ? 'rgba(240,169,59,0.20)' : 'rgba(224,138,0,0.14)';
      case AppColor.INSIGHT_DANGER:
        return night ? 'rgba(239,91,91,0.18)' : 'rgba(198,40,40,0.10)';
      default:
        return night ? 'rgba(76,196,106,0.18)' : 'rgba(46,125,50,0.12)';
    }
  }

  /** 研判分级 → 标签文字色 */
  static insightText(level: string): string {
    const night: boolean = ThemeStore.isNight();
    switch (level) {
      case AppColor.INSIGHT_ATTENTION:
        return night ? '#F0B65C' : '#B26A00';
      case AppColor.INSIGHT_DANGER:
        return AppColor.DANGER;
      default:
        return night ? '#5FD37C' : '#2C7A38';
    }
  }

  /** 研判分级 → 卡片描边色 */
  static insightBorder(level: string): string {
    const night: boolean = ThemeStore.isNight();
    switch (level) {
      case AppColor.INSIGHT_ATTENTION:
        return night ? 'rgba(240,169,59,0.50)' : 'rgba(224,138,0,0.45)';
      case AppColor.INSIGHT_DANGER:
        return night ? 'rgba(239,91,91,0.45)' : 'rgba(198,40,40,0.40)';
      default:
        return night ? 'rgba(76,196,106,0.38)' : 'rgba(46,125,50,0.32)';
    }
  }
}

/**
 * 尺寸。
 *
 * 关怀模式下整体放大：字号 ×1.22，图标单独放大。
 * 只放大字号与图标、不放大间距，是因为老人需要的是"看得清"，
 * 不是"屏幕变松"；间距跟着放大会让一屏能看的内容变少，反而更难用。
 */
export class AppSize {
  /** 关怀模式字号放大系数 */
  private static readonly CARE_SCALE: number = 1.22;

  private static scale(): number {
    return ThemeStore.careOn() ? AppSize.CARE_SCALE : 1;
  }

  static get PAGE_PADDING(): number {
    return 16;
  }

  static get CARD_RADIUS(): number {
    return 12;
  }

  static get SMALL_RADIUS(): number {
    return 8;
  }

  static get TITLE_FONT(): number {
    return Math.round(22 * AppSize.scale());
  }

  /** 顶部标题栏大标题（比 TITLE_FONT 再大一级） */
  static get HEADER_FONT(): number {
    return Math.round(24 * AppSize.scale());
  }

  /** 首页「待处置数量」这类需要一眼看到的特大数字 */
  static get BIG_FONT(): number {
    return Math.round(26 * AppSize.scale());
  }

  static get SUBTITLE_FONT(): number {
    return Math.round(16 * AppSize.scale());
  }

  static get BODY_FONT(): number {
    return Math.round(15 * AppSize.scale());
  }

  static get CAPTION_FONT(): number {
    return Math.round(13 * AppSize.scale());
  }

  static get SMALL_FONT(): number {
    return Math.round(11 * AppSize.scale());
  }

  /** 传感器卡片图标字号。关怀模式单独放大，比字号系数更大一档 */
  static get ICON_FONT(): number {
    return ThemeStore.careOn() ? 26 : 20;
  }

  /** 宫格图标字号 */
  static get GLYPH_FONT(): number {
    return ThemeStore.careOn() ? 19 : 15;
  }

  /** 宫格图标底块边长 */
  static get GLYPH_BOX(): number {
    return ThemeStore.careOn() ? 42 : 34;
  }

  /** 小标签字号（SOS 角标、等级小签等） */
  static get TAG_FONT(): number {
    return ThemeStore.careOn() ? 12 : 9;
  }
}
