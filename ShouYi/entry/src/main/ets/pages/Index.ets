import { HomePage } from '../view/HomePage';
import { RealtimeStatusPage } from '../view/RealtimeStatusPage';
import { ActivityReportPage } from '../view/ActivityReportPage';
import { AlertCenterPage } from '../view/AlertCenterPage';
import { MinePage } from '../view/MinePage';
import { CareService } from '../service/CareService';
import { AppColor } from '../common/constants/ThemeColors';
import { Logger } from '../common/utils/Logger';

import { ThemeMode, ThemeStore } from '../common/theme/ThemeStore';
/**
 * 应用主框架 —— 五 Tab 容器。
 *
 * 这是 EntryAbility 启动后加载的第一个页面（`windowStage.loadContent('pages/Index')`）。
 * 职责很单一：承载五个业务页面并维护底部导航，自身不含任何业务逻辑。
 *
 * 五个 Tab 的分工（首页 → 四大模块）：
 *   首页      → 只回答"有没有待处理"，并给出四个模块入口
 *   实时状态  → 各传感器当前值与历史曲线
 *   活动报告  → 活动时段分布 / 频次趋势 / 周月报告
 *   预警中心  → 历史预警查询、详情与处置闭环
 *   设置与设备 → 家庭成员与角色、居家安全日志、演示与设置
 *
 * 设计取舍一：底部导航用文字标签而不是图标。
 * 原因见工程 README —— 本工程刻意不引入位图图标资源，避免为凑图标引入
 * 版权不明的素材；纯文字 + 色块指示同样能清晰表达层级，且在任何分辨率下不失真。
 *
 * 设计取舍二：首页宫格不 push 新页面，而是切换 Tab。
 * 五个 Tab 已经把功能分完了，再叠一层"首页 → 二级页 → 返回"只会让层级变深，
 * 对老年人家属这类低频用户不友好。所以 HomePage 通过 onNavigate 回调直接切 Tab。
 */
@Entry
@Component
struct Index {

  /**
   * 订阅显示设置。@StorageProp 会在主题 / 关怀模式变化时触发本组件重渲染，
   * 这样 ThemeStore 一改，AppColor / AppSize 的 getter 重新取值，全页同步换肤。
   */
  @StorageProp('displayMode') displayMode: string = 'day';
  @StorageProp('careMode') careMode: boolean = false;
  private static readonly MODULE: string = 'Index';

  /** 预警中心的 Tab 下标（角标挂在这里） */
  private static readonly TAB_ALERT: number = 3;

  /** 当前选中的 Tab 下标 */
  @State currentIndex: number = 0;
  /** 待处置预警数，用于"预警中心"Tab 的角标 */
  @State pendingCount: number = 0;
  /**
   * 页签切换广播信号。
   * 每次切页签 +1，五个页签都通过 @StorageLink 监听并重新拉各自的数据 ——
   * 否则页签缓存会停在旧数据：在预警中心处置完切回首页，
   * 首页的待处理数还停留在进入预警中心之前的值。
   */
  @StorageLink('alertRefreshTick') alertTick: number = 0;

  private service: CareService = new CareService();
  private tabsController: TabsController = new TabsController();

  aboutToAppear(): void {
    this.refreshBadge();
  }

  /**
   * 刷新待处置角标。
   * 切到预警 Tab 或从详情页返回时都会调用，保证角标与实际状态一致。
   */
  async refreshBadge(): Promise<void> {
    try {
      this.pendingCount = await this.service.countPendingAlerts();
    } catch (err) {
      // 角标是辅助信息，取不到就不显示，不能因此影响主流程
      Logger.warn(Index.MODULE, `刷新待处置角标失败: ${(err as Error).message}`);
      this.pendingCount = 0;
    }
  }

  /** 首页宫格 → 切换对应 Tab */
  private goToTab(index: number): void {
    this.currentIndex = index;
    this.tabsController.changeIndex(index);
    if (index === Index.TAB_ALERT) {
      this.refreshBadge();
    }
  }

  /**
   * 主题签名：日间/夜间 × 关怀模式，四种组合各走一支。
   *
   * 每一支都调用同一个 @Builder pageRoot()。主题任一维度变化都会换分支，
   * ArkUI 随之销毁旧子树、重建新子树 —— 这是必须的：
   * AppColor / AppSize 是静态 getter，ArkTS 追踪不到它们内部读的 AppStorage，
   * 所以「没有依赖被追踪状态」的属性表达式切主题时不会重新求值。
   * 只有整棵子树重建，静态 getter 才会拿到新值。
   */

  build() {
    if (this.displayMode === ThemeMode.NIGHT && this.careMode) {
      this.pageRoot();
    } else if (this.displayMode === ThemeMode.NIGHT) {
      this.pageRoot();
    } else if (this.careMode) {
      this.pageRoot();
    } else {
      this.pageRoot();
    }
  }

  @Builder
  pageRoot() {
      Tabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.tabsController }) {
        TabContent() {
          HomePage({
            onNavigate: (index: number) => {
              this.goToTab(index);
            }
          })
        }
        .tabBar(this.tabItem(0, '首页'))

        TabContent() {
          RealtimeStatusPage()
        }
        .tabBar(this.tabItem(1, '实时状态'))

        TabContent() {
          ActivityReportPage()
        }
        .tabBar(this.tabItem(2, '活动报告'))

        TabContent() {
          AlertCenterPage()
        }
        .tabBar(this.tabItem(Index.TAB_ALERT, '预警中心'))

        TabContent() {
          MinePage()
        }
        .tabBar(this.tabItem(4, '设置与设备'))
      }
      .barMode(BarMode.Fixed)
      .barHeight(58)
      .barBackgroundColor(AppColor.CARD)
      .scrollable(true)
      .animationDuration(200)
      .onChange((index: number) => {
        this.currentIndex = index;
        // 每次切页签都广播一次刷新信号 + 刷角标。
        // Tabs 会缓存页签，各页的 aboutToAppear 终生只跑一次；
        // 不广播的话，在预警中心处置完切回首页，首页的待处理数还停在旧值，
        // 页签角标也对不上 —— 这是「首页与预警中心不同步」的根因。
        this.refreshBadge();
        this.alertTick = this.alertTick + 1;
      })
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.BG)

  }


  /**
   * 单个底部导航项。
   * 选中态用主色 + 加粗 + 顶部指示条，未选中态弱化为次文本色。
   *
   * 字号比上一版小一档（13/12）：五个 Tab 里"设置与设备"是五个字，
   * 按 14px 在 360dp 屏上会顶到相邻 Tab，缩一档才能完整显示。
   */
  @Builder
  tabItem(index: number, title: string) {
    Column() {
      // 顶部指示条：选中时显示主色，未选中时透明占位（避免文字跳动）
      Divider()
        .width(18)
        .strokeWidth(3)
        .color(this.currentIndex === index ? AppColor.ACCENT : Color.Transparent)
        .margin({ bottom: 5 })

      Row() {
        Text(title)
          .fontSize(this.currentIndex === index ? 13 : 12)
          .fontWeight(this.currentIndex === index ? FontWeight.Bold : FontWeight.Normal)
          .fontColor(this.currentIndex === index ? AppColor.ACCENT : AppColor.TEXT_3)
          .maxLines(1)

        // 仅"预警中心"Tab 显示待处置角标
        if (index === Index.TAB_ALERT && this.pendingCount > 0) {
          Text(this.pendingCount > 99 ? '99+' : `${this.pendingCount}`)
            .fontSize(9)
            .fontColor(AppColor.ON_PRIMARY)
            .backgroundColor(AppColor.DANGER)
            .borderRadius(9)
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .margin({ left: 2 })
        }
      }
      .alignItems(VerticalAlign.Center)
      .justifyContent(FlexAlign.Center)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
