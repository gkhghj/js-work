import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from '../utils/Logger';

/**
 * 显示模式：主题亮度维度。
 *
 * 注意这是**两个相互独立的维度**之一，另一个是「关怀模式」（见 ThemeStore.careOn）。
 *   日间 / 夜间  → 只改屏幕底色与文字明暗（配色）
 *   关怀模式     → 独立开关，管信息密度 + 字号尺寸
 * 两者可自由组合：关怀+日间、关怀+夜间、标准+日间、标准+夜间。
 */
export class ThemeMode {
  static readonly DAY: string = 'day';
  static readonly NIGHT: string = 'night';
}

/**
 * 显示设置的状态中心。
 *
 * 为什么放在 AppStorage 而不是各页面 @State：
 * 主题与关怀模式是全局设置，五个 Tab 都要同时生效。AppStorage 是 ArkUI
 * 里唯一能让"一处修改、多处重渲染"的共享通道；页面只需声明
 * `@StorageProp('displayMode')` / `@StorageProp('careMode')` 即可订阅。
 *
 * 为什么 AppColor / AppSize 用静态 getter 读这里：
 * 全工程有几百处 `AppColor.BG`、`AppSize.BODY_FONT` 调用。改成实例注入
 * 等于把每个页面都重写一遍。用 getter 读全局状态，调用点一行都不用动。
 */
export class ThemeStore {
  private static readonly MODULE: string = 'ThemeStore';

  /** Preferences 文件名与键（持久化，重启后保持上次选择） */
  private static readonly PREF_NAME: string = 'shouyi_display';
  private static readonly KEY_MODE: string = 'display_mode';
  private static readonly KEY_CARE: string = 'care_mode';

  /** AppStorage 键名，页面用 @StorageProp 订阅这两个 */
  static readonly STORAGE_MODE: string = 'displayMode';
  static readonly STORAGE_CARE: string = 'careMode';

  private static store: preferences.Preferences | undefined = undefined;

  /**
   * 应用启动时调用（EntryAbility.onCreate）。
   *
   * 先把默认值写进 AppStorage —— 否则页面首帧读到 undefined 会闪一下日间配色。
   * 再尝试读持久化值覆盖；读失败就保持默认，不能因为设置读取失败而阻塞启动。
   */
  static init(context: common.Context): void {
    if (AppStorage.get<string>(ThemeStore.STORAGE_MODE) === undefined) {
      AppStorage.setOrCreate<string>(ThemeStore.STORAGE_MODE, ThemeMode.DAY);
    }
    if (AppStorage.get<boolean>(ThemeStore.STORAGE_CARE) === undefined) {
      AppStorage.setOrCreate<boolean>(ThemeStore.STORAGE_CARE, false);
    }

    try {
      ThemeStore.store = preferences.getPreferencesSync(context, { name: ThemeStore.PREF_NAME });
      const mode: string = ThemeStore.store.getSync(ThemeStore.KEY_MODE, ThemeMode.DAY) as string;
      const care: boolean = ThemeStore.store.getSync(ThemeStore.KEY_CARE, false) as boolean;
      AppStorage.setOrCreate<string>(ThemeStore.STORAGE_MODE, mode);
      AppStorage.setOrCreate<boolean>(ThemeStore.STORAGE_CARE, care);
      Logger.info(ThemeStore.MODULE, `显示设置已载入：${mode} / 关怀=${care}`);
    } catch (err) {
      Logger.warn(ThemeStore.MODULE, `显示设置读取失败，使用默认值: ${(err as Error).message}`);
    }
  }

  /** 当前主题模式 */
  static mode(): string {
    const m: string | undefined = AppStorage.get<string>(ThemeStore.STORAGE_MODE);
    return m === undefined ? ThemeMode.DAY : m;
  }

  /** 是否夜间 */
  static isNight(): boolean {
    return ThemeStore.mode() === ThemeMode.NIGHT;
  }

  /** 关怀模式是否开启 */
  static careOn(): boolean {
    return AppStorage.get<boolean>(ThemeStore.STORAGE_CARE) === true;
  }

  /** 切换主题（日间 ⇄ 夜间） */
  static setMode(mode: string): void {
    AppStorage.setOrCreate<string>(ThemeStore.STORAGE_MODE, mode);
    ThemeStore.persist(ThemeStore.KEY_MODE, mode);
  }

  /** 直接设置关怀模式 */
  static setCare(on: boolean): void {
    AppStorage.setOrCreate<boolean>(ThemeStore.STORAGE_CARE, on);
    ThemeStore.persist(ThemeStore.KEY_CARE, on);
  }

  /** 切换关怀模式 */
  static toggleCare(): void {
    ThemeStore.setCare(!ThemeStore.careOn());
  }

  /** 写盘。失败只记日志，不影响当前会话已经生效的界面状态 */
  private static persist(key: string, value: preferences.ValueType): void {
    if (ThemeStore.store === undefined) {
      return;
    }
    try {
      ThemeStore.store.putSync(key, value);
      ThemeStore.store.flush().then(() => {
      }).catch((err: Error) => {
        Logger.warn(ThemeStore.MODULE, `显示设置落盘失败: ${err.message}`);
      });
    } catch (err) {
      Logger.warn(ThemeStore.MODULE, `显示设置落盘失败: ${(err as Error).message}`);
    }
  }
}
