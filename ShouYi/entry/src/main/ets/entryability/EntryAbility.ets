import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { NetworkMonitor } from '../service/NetworkMonitor';
import { AppConfig } from '../cloud/CloudApiFactory';
import { IotDaCloudAdapter } from '../cloud/IotDaCloudAdapter';
import { IotDaConfig } from '../cloud/IotDaConfig';
import { Logger } from '../common/utils/Logger';
import { ThemeStore } from '../common/theme/ThemeStore';

/**
 * 应用入口 Ability。
 *
 * 启动编排：
 *   1. 启动网络监听（为离线降级做准备）
 *   2. 加载首页
 *
 * 与赛题一不同：本作品不在启动时做本地数据库预置，
 * 因为设备与告警数据都来自云端，本地只做轻量缓存。
 */
export default class EntryAbility extends UIAbility {
  private static readonly MODULE: string = 'EntryAbility';

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(EntryAbility.MODULE, 'Ability onCreate');

    // 0) 显示设置（日间/夜间、关怀模式）必须最先载入：
    //    页面首帧就要读到正确主题，否则会先闪一下日间配色再跳变。
    ThemeStore.init(this.context);


    // 1) 切到华为云 IoTDA（IAM 子用户，token 自动续期）
    if (IotDaConfig.ENABLED) {
      AppConfig.switchToIotDaAuto(
        IotDaConfig.ENDPOINT, IotDaConfig.REGION, IotDaConfig.PROJECT_ID,
        IotDaConfig.DEVICE_ID, IotDaConfig.FAMILY_ID,
        IotDaConfig.DOMAIN_NAME, IotDaConfig.USER_NAME, IotDaConfig.PASSWORD);
    }

    // 2) 把沙箱目录注入适配器，开启告警 / 安全日志 / 活动统计的本地持久化。
    //    平台不提供这些业务数据，必须落在 App 端。
    const api = AppConfig.getCloudApi();
    if (api instanceof IotDaCloudAdapter) {
      const adapter: IotDaCloudAdapter = api as IotDaCloudAdapter;
      adapter.initStore(this.context.filesDir);

      // 3) 演示数据：活动统计 / 告警历史 / 安全日志的真实数据要 App 长期在线才攒得出来，
      //    刚装机或板子离线时全是空的，活动报告与预警中心没法看。
      //    这里种一份 60 天的底稿 —— 只补缺口，真实数据优先，随时可关。
      if (IotDaConfig.DEMO_MODE) {
        adapter.seedDemoData(IotDaConfig.DEVICE_ID, IotDaConfig.DEVICE_NAME);
      }
    }
  }

  async onWindowStageCreate(windowStage: window.WindowStage): Promise<void> {
    Logger.info(EntryAbility.MODULE, '窗口创建，开始初始化');

    // 网络监听：网络恢复后由各页面自行触发刷新
    NetworkMonitor.start();
    await NetworkMonitor.refresh();

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        Logger.error(EntryAbility.MODULE, `加载首页失败: ${err.code} ${err.message}`);
        return;
      }
      Logger.info(EntryAbility.MODULE, '首页加载完成');
    });
  }

  onDestroy(): void {
    Logger.info(EntryAbility.MODULE, 'Ability onDestroy');
  }

  onForeground(): void {
    Logger.info(EntryAbility.MODULE, '应用进入前台');
  }

  onBackground(): void {
    Logger.info(EntryAbility.MODULE, '应用进入后台');
  }
}
