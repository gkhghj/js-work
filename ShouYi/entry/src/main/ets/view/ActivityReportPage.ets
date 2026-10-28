import { ActivityReport } from '../model/ActivityRecord';
import { CareService } from '../service/CareService';
import { ActivityAnalysisService } from '../service/ActivityAnalysisService';
import { ActivityHeatmap } from './components/ActivityHeatmap';
import { TrendChart } from './components/TrendChart';
import { AppColor, AppSize } from '../common/constants/ThemeColors';
import { ReportExporter } from '../common/utils/ReportExporter';
import { AppConstants } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';
import { common } from '@kit.AbilityKit';

import { ThemeMode, ThemeStore } from '../common/theme/ThemeStore';
/**
 * 活动报告页。
 *
 * 赛题"数据统计分析"要求的落点，也是本作品相对普通监护产品最能体现
 * "不只是数据展示"的一页。月报为默认视图（路演主视角），日报 / 周报可即时切换。
 *
 * 页面结构（自上而下）：
 *   ① 标题栏：活动报告 + 导出 PDF + 鸿星伴护
 *   ② 周期切换：日报 / 周报 / 月报
 *   ③ 智能研判 —— 自然语言结论，分级配色
 *   ④ 活动时段热力图 —— 横轴 24 小时，纵轴日期，绿到深蓝
 *   ⑤ 每日活动频次趋势 —— 绿色折线 + 浅绿填充 + 黄色个性化基线虚线
 *   ⑥ 个人作息基线模型 —— 基线均值 / 波动区间 / 整体偏离度
 *
 * 配色铁律：绿色=正常，橙黄=健康关注，红色只留给紧急告警，
 * 本页任何字段都不使用红色（已在文末 noteStyle 等各处落实）。
 */
@Component
export struct ActivityReportPage {

  /**
   * 订阅显示设置。@StorageProp 会在主题 / 关怀模式变化时触发本组件重渲染，
   * 这样 ThemeStore 一改，AppColor / AppSize 的 getter 重新取值，全页同步换肤。
   */
  @StorageProp('displayMode') displayMode: string = 'day';
  @StorageProp('careMode') careMode: boolean = false;
  private static readonly MODULE: string = 'ActivityReportPage';

  @State report: ActivityReport | undefined = undefined;
  @State period: string = 'month';
  @State loading: boolean = true;
  /** 隐私边界：网格员与物业不可查看活动报告 */
  @State canView: boolean = true;
  /** 研判分级：normal / attention / danger */
  @State insightLevel: string = 'normal';
  /** 页签切换广播：Tabs 缓存页签，aboutToAppear 只跑一次，回本页要重新拉报告 */
  @StorageLink('alertRefreshTick') @Watch('onAlertRefreshTick') alertTick: number = 0;


  private service: CareService = new CareService();

  aboutToAppear(): void {
    this.canView = this.service.canViewActivity();
    if (this.canView) {
      this.load();
    }
  }

  /** 每次切回本页签都重新拉，否则处置完告警回来报告还是旧的 */
  onAlertRefreshTick(): void {
    this.canView = this.service.canViewActivity();
    if (this.canView) {
      this.load();
    }
  }

  async load(): Promise<void> {
    this.loading = true;
    try {
      this.report = await this.service.loadActivityReport(this.period);
      if (this.report !== undefined) {
        this.insightLevel = ActivityAnalysisService.insightLevel(this.report);
        Logger.info(ActivityReportPage.MODULE,
          `报告就绪 period=${this.report.period} total=${this.report.totalCount} `
            + `avg=${this.report.avgDailyCount}`);
      }
    } catch (err) {
      Logger.error(ActivityReportPage.MODULE, `加载报告失败: ${(err as Error).message}`);
    } finally {
      this.loading = false;
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
      Column() {
        // ---------- 标题栏 ----------
        // 「导出 PDF」常驻标题栏：交接场景里这个入口不该在需要它的时候已经划过去了
        Row() {
          Text('活动报告')
            .fontSize(AppSize.TITLE_FONT)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.TEXT)
            .layoutWeight(1)

          Text('导出 PDF')
            .fontSize(AppSize.CAPTION_FONT)
            .fontColor(AppColor.ON_PRIMARY)
            .backgroundColor(AppColor.PRIMARY)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .margin({ right: 10 })
            .onClick(() => {
              this.exportReport();
            })

          // 「鸿星伴护」作品名。压在导出按钮右侧，弱化为小字而非并排按钮，
          // 避免把唯一的主操作挤出视觉重心
          Text('鸿星伴护')
            .fontSize(AppSize.SMALL_FONT)
            .fontColor(AppColor.TEXT_3)
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding(AppSize.PAGE_PADDING)

        if (!this.canView) {
          // ---------- 隐私边界提示 ----------
          Column() {
            Text('活动报告仅对直系家属开放')
              .fontSize(AppSize.BODY_FONT)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.TEXT)
            Text('活动数据反映老人的生活细节，出于隐私保护，'
              + '社区网格员与物业值班仅接收预警信息与处置任务，不查看活动数据。')
              .fontSize(AppSize.CAPTION_FONT)
              .fontColor(AppColor.TEXT_2)
              .margin({ top: 10 })
              .lineHeight(22)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(16)
          .backgroundColor(AppColor.CARD)
          .borderRadius(AppSize.CARD_RADIUS)
          .margin({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
          .layoutWeight(1)
        } else {
          Scroll() {
            Column() {
              // ---------- 周期切换 ----------
              Row() {
                this.periodChip('day', '日报')
                this.periodChip('week', '周报')
                this.periodChip('month', '月报')
              }
              .width('100%')
              .margin({ bottom: 12 })

              if (this.report !== undefined) {
                // ---------- 智能研判 ----------
                Column() {
                  Row() {
                    Text(this.insightBadgeText())
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.insightText(this.insightLevel))
                      .backgroundColor(AppColor.insightBg(this.insightLevel))
                      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                      .borderRadius(4)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text('智能研判')
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.TEXT_3)
                      .margin({ left: 8 })
                  }
                  .width('100%')

                  Text(`智能研判：${this.report.insight}`)
                    .fontSize(AppSize.BODY_FONT)
                    .fontColor(AppColor.TEXT)
                    .lineHeight(24)
                    .margin({ top: 12 })
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(16)
                .backgroundColor(AppColor.CARD)
                .borderRadius(AppSize.CARD_RADIUS)
                .border({ width: 1, color: AppColor.insightBorder(this.insightLevel) })
                .margin({ bottom: 12 })

                // ---------- ③ 本期概览（四个关键数字） ----------
                //
                // ⚠️ 这四块必须直接写 `this.report.xxx`，不能走子组件、@Builder 或
                // this.xxx() 方法取值。实测（切到日报后逐版验证）：
                //   · Text(`${this.report.insight}`) —— 直接属性访问 → 正常刷新
                //   · 传给子组件 @Prop（对象 / 基础类型都试过） → 停在月报的数字
                //   · 走 this.totalText() 方法取值 → 同样停在月报
                // 结果就是同一屏里智能研判写着「日均 68 次」，概览卡还是 790 次。
                // ArkUI 的依赖追踪只认 build 表达式里直接出现的状态属性，
                // 所以这里宁可重复四段排版，也要让依赖看得见。
                Column() {
                  Row() {
                    Text('本期概览')
                      .fontSize(AppSize.SUBTITLE_FONT)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                      .layoutWeight(1)
                    Text(this.periodLabel())
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.TEXT_3)
                  }
                  .width('100%')
                  .margin({ bottom: 14 })

                  Row() {
                    Column() {
                      Row() {
                        Text(`${this.report.totalCount}`)
                          .fontSize(AppSize.BIG_FONT)
                          .fontWeight(FontWeight.Bold)
                          .fontColor(AppColor.PRIMARY)
                        Text('次')
                          .fontSize(AppSize.SMALL_FONT)
                          .fontColor(AppColor.TEXT_3)
                          .margin({ left: 3, bottom: 4 })
                      }
                      .alignItems(VerticalAlign.Bottom)
                      Text('活动总次数')
                        .fontSize(AppSize.SMALL_FONT)
                        .fontColor(AppColor.TEXT_3)
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Divider()
                      .vertical(true)
                      .height(30)
                      .color(AppColor.LINE)
                      .margin({ left: 10, right: 10 })

                    Column() {
                      Row() {
                        Text(this.report.avgDailyCount > 0 ? `${this.report.avgDailyCount}` : '—')
                          .fontSize(AppSize.BIG_FONT)
                          .fontWeight(FontWeight.Bold)
                          .fontColor(AppColor.PRIMARY)
                        Text('次/天')
                          .fontSize(AppSize.SMALL_FONT)
                          .fontColor(AppColor.TEXT_3)
                          .margin({ left: 3, bottom: 4 })
                      }
                      .alignItems(VerticalAlign.Bottom)
                      Text('日均活动')
                        .fontSize(AppSize.SMALL_FONT)
                        .fontColor(AppColor.TEXT_3)
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')

                  Divider()
                    .color(AppColor.LINE)
                    .margin({ top: 12, bottom: 12 })

                  Row() {
                    Column() {
                      Row() {
                        Text(`${this.report.nightActivityCount}`)
                          .fontSize(AppSize.BIG_FONT)
                          .fontWeight(FontWeight.Bold)
                          .fontColor(AppColor.PRIMARY)
                        Text('次')
                          .fontSize(AppSize.SMALL_FONT)
                          .fontColor(AppColor.TEXT_3)
                          .margin({ left: 3, bottom: 4 })
                      }
                      .alignItems(VerticalAlign.Bottom)
                      Text('夜间活动')
                        .fontSize(AppSize.SMALL_FONT)
                        .fontColor(AppColor.TEXT_3)
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Divider()
                      .vertical(true)
                      .height(30)
                      .color(AppColor.LINE)
                      .margin({ left: 10, right: 10 })

                    Column() {
                      Row() {
                        Text(`${this.report.activeHours}`)
                          .fontSize(AppSize.BIG_FONT)
                          .fontWeight(FontWeight.Bold)
                          .fontColor(AppColor.PRIMARY)
                        Text('个')
                          .fontSize(AppSize.SMALL_FONT)
                          .fontColor(AppColor.TEXT_3)
                          .margin({ left: 3, bottom: 4 })
                      }
                      .alignItems(VerticalAlign.Bottom)
                      Text('活跃时段')
                        .fontSize(AppSize.SMALL_FONT)
                        .fontColor(AppColor.TEXT_3)
                        .margin({ top: 2 })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }
                  .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(16)
                .backgroundColor(AppColor.CARD)
                .borderRadius(AppSize.CARD_RADIUS)
                .margin({ bottom: 12 })

                // ---------- ① 活动时段热力图 ----------
                Column() {
                  Row() {
                    Text('活动时段热力图')
                      .fontSize(AppSize.SUBTITLE_FONT)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                      .layoutWeight(1)
                    Text('颜色越深活动越频繁')
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.TEXT_3)
                  }
                  .width('100%')
                  .margin({ bottom: 10 })

                  ActivityHeatmap({ report: this.report, chartWidth: 304 })

                  Text(this.heatmapNote())
                    .fontSize(AppSize.SMALL_FONT)
                    .fontColor(AppColor.TEXT_3)
                    .margin({ top: 10 })
                    .lineHeight(18)
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(16)
                .backgroundColor(AppColor.CARD)
                .borderRadius(AppSize.CARD_RADIUS)
                .margin({ bottom: 12 })

                // ---------- ② 每日活动频次趋势 ----------
                Column() {
                  Row() {
                    Text('每日活动频次趋势')
                      .fontSize(AppSize.SUBTITLE_FONT)
                      .fontWeight(FontWeight.Bold)
                      .fontColor(AppColor.TEXT)
                      .layoutWeight(1)
                    // 基线数值来自老人自己的 14 天历史，不是页面写死的数字
                    Text(`虚线 = 老人个性化基线均值${this.baselineText()}`)
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.TEXT_3)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                  }
                  .width('100%')
                  .margin({ bottom: 10 })

                  // 配色按本页规范：折线绿、填充浅绿、基线黄
                  // 日报窗口只有 1 天，改用 dailyTrend（近 14 天），否则图上只有一个点
                  TrendChart({
                    points: this.period === 'day' ? this.report.dailyTrend : this.report.daily,
                    chartWidth: 320,
                    chartHeight: 170,
                    lineColor: AppColor.SUCCESS,
                    fillColor: 'rgba(46,125,50,0.13)',
                    baseline: this.report.baselineAvg,
                    baselineColor: AppColor.WARNING,
                    showBaselineLabel: this.report.baselineAvg > 0
                  })

                  Text('系统基于老人历史数据动态生成个性化基线，当数值大幅偏离基线，'
                    + '将触发健康关注提示，而非固定阈值判断。')
                    .fontSize(AppSize.SMALL_FONT)
                    .fontColor(AppColor.TEXT_3)
                    .margin({ top: 10 })
                    .lineHeight(18)
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(16)
                .backgroundColor(AppColor.CARD)
                .borderRadius(AppSize.CARD_RADIUS)
                .margin({ bottom: 12 })

                // ---------- ③ 个人作息基线模型 ----------
                Column() {
                  Text('个人作息基线模型')
                    .fontSize(AppSize.SUBTITLE_FONT)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(AppColor.TEXT)
                    .width('100%')

                  Text('基线基于老人近 14 天历史数据动态生成，以老人自身习惯作为判断标准，'
                    + '规避固定阈值带来的误报。')
                    .fontSize(AppSize.SMALL_FONT)
                    .fontColor(AppColor.TEXT_3)
                    .margin({ top: 8 })
                    .lineHeight(18)
                    .width('100%')

                  if (this.report.baselineAvg > 0) {
                    Row() {
                      this.metric('基线均值', this.baselineText())
                      this.metric('波动区间', `±${this.report.baselineStdDev}`)
                      // 偏离度 + 同色圆点：颜色与文字分离在两个组件上，
                      // 让"正常"这件事既读得到也看得见
                      this.metric(`${this.periodLabel()}整体偏离度`, this.deviationText())
                    }
                    .width('100%')
                    .margin({ top: 16 })

                    Row() {
                      Row()
                        .width(8)
                        .height(8)
                        .borderRadius(4)
                        .backgroundColor(this.deviationColor())
                        .margin({ right: 6 })
                      Text(this.deviationLabel())
                        .fontSize(AppSize.CAPTION_FONT)
                        .fontColor(this.deviationColor())
                    }
                    .width('100%')
                    .alignItems(VerticalAlign.Center)
                    .margin({ top: 10 })
                  } else {
                    Text('该老人暂无足够的连续历史数据，基线模型暂未建立。')
                      .fontSize(AppSize.CAPTION_FONT)
                      .fontColor(AppColor.TEXT_3)
                      .margin({ top: 16 })
                      .width('100%')
                  }

                  Text('σ为标准差，偏离超过 ±2σ 触发健康关注提示，'
                    + '仅健康参考，不属于紧急告警。')
                    .fontSize(AppSize.SMALL_FONT)
                    .fontColor(AppColor.TEXT_3)
                    .margin({ top: 12 })
                    .lineHeight(18)
                    .width('100%')
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(16)
                .backgroundColor(AppColor.CARD)
                .borderRadius(AppSize.CARD_RADIUS)
              } else if (!this.loading) {
                Text('暂无活动数据')
                  .fontSize(AppSize.BODY_FONT)
                  .fontColor(AppColor.TEXT_3)
                  .margin({ top: 60 })
              }

              Blank().height(20)
            }
            .width('100%')
            .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.BG)

  }


  // ==================== 文案 ====================

  /** 基线均值文案。无基线时给占位而不是空白 */
  private baselineText(): string {
    const v: number = this.report !== undefined ? this.report.baselineAvg : 0;
    return v > 0 ? `${v}` : '--';
  }

  /** 偏离度文案，如 "-0.28σ" */
  private deviationText(): string {
    const d: number = this.report !== undefined ? this.report.deviation : 0;
    if (this.report === undefined || this.report.baselineAvg <= 0) {
      return '--';
    }
    const sign: string = d > 0 ? '+' : '';
    return `${sign}${d}σ`;
  }

  /**
   * 偏离度状态文字。
   * 只分"正常区间"与"偏离基线"两档，刻意不用告警口吻 ——
   * 这一栏的健康参考属性必须一眼可辨。
   */
  private deviationLabel(): string {
    if (this.report === undefined || this.report.baselineAvg <= 0) {
      return '基线模型建立中';
    }
    return Math.abs(this.report.deviation) >= AppConstants.BASELINE_DEVIATION_SIGMA ? '偏离个人基线，建议关注' : '处于正常区间';
  }

  /** 偏离度颜色。绿=正常、橙黄=偏离。本页不用红色 */
  private deviationColor(): string {
    if (this.report === undefined || this.report.baselineAvg <= 0) {
      return AppColor.TEXT_3;
    }
    return Math.abs(this.report.deviation) >= AppConstants.BASELINE_DEVIATION_SIGMA ? AppColor.WARNING : AppColor.SUCCESS;
  }

  /** 热力图脚注：日报与周/月报的行含义不同，文案必须跟着变 */
  private heatmapNote(): string {
    if (this.period === 'day') {
      return '横轴：24小时；纵轴：近 7 天（今日在最末行）；色块颜色越深代表活动频次越高，'
        + '支持点击任意格子查看该时段的实际活动次数。';
    }
    return '横轴：24小时；纵轴：日期；色块颜色越深代表活动频次越高，'
      + '可直观识别作息波动、夜间异常活动时段，支持点击查看单日详情。';
  }

  /** 周期描述词：本日 / 本周 / 本月 */
  private periodLabel(): string {
    switch (this.period) {
      case 'day':
        return '本日';
      case 'week':
        return '本周';
      default:
        return '本月';
    }
  }

  /**
   * 研判标签：分级词 + 趋势摘要，形如「关注提示｜与上周活动总量持平」。
   */
  private insightBadgeText(): string {
    if (this.report === undefined) {
      return '分析中';
    }
    const levelWord: string = this.insightLevel === 'danger' ? '异常告警'
      : (this.insightLevel === 'attention' ? '关注提示' : '正常');
    const delta: string = Math.abs(this.report.changePercent) > 0
      ? ` ${Math.abs(this.report.changePercent)}%`
      : '';
    let summary: string = `与${this.report.compareWith}活动总量持平`;
    if (this.report.trendDirection === 'down') {
      summary = `活动总量较${this.report.compareWith}下降${delta}`;
    } else if (this.report.trendDirection === 'up') {
      summary = `活动总量较${this.report.compareWith}上升${delta}`;
    }
    return `${levelWord}｜${summary}`;
  }

  // ==================== 导出 ====================

  /**
   * 导出报告：生成结构化报告文本并调起系统分享面板。
   *
   * 说明：HarmonyOS 的原生 PDF 生成需要 @kit.PDFKit，
   * 它依赖独立的 ohos pdfkit npm 包，本工程未引入该依赖。
   * 因此落地为"结构化报告文本 + 系统分享面板"，
   * 在分享面板中选择「打印」即可由系统另存为 PDF —— 对纯文本这是最稳的路径。
   */
  private exportReport(): void {
    if (this.report === undefined) {
      this.toast('暂无报告可导出');
      return;
    }
    try {
      // getContext 已废弃，自定义组件里用 getUIContext().getHostContext() 取宿主上下文
      const context: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      ReportExporter.share(context, this.report, this.elderName());
    } catch (err) {
      Logger.error(ActivityReportPage.MODULE, `导出报告失败: ${(err as Error).message}`);
      this.toast('导出失败，请稍后重试');
    }
  }

  /** 被监护老人姓名。取不到时退回中性称呼，不留占位符 */
  private elderName(): string {
    return this.service.boundElderName() ?? '家中老人';
  }

  /**
   * 轻提示。
   * showToast 声明为可能抛异常，必须包 try —— 这是工程里既有约定
   * （AlertCard.toast 同样处理），否则每次编译都留 warning 尾巴。
   */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      Logger.warn(ActivityReportPage.MODULE, `提示未弹出: ${(err as Error).message}`);
    }
  }

  // ==================== 组件 ====================

  @Builder
  periodChip(key: string, label: string) {
    Text(label)
      .fontSize(AppSize.CAPTION_FONT)
      .fontColor(this.period === key ? AppColor.ON_PRIMARY: AppColor.TEXT_2)
      .backgroundColor(this.period === key ? AppColor.PRIMARY : AppColor.CARD)
      .padding({ left: 18, right: 18, top: 8, bottom: 8 })
      .borderRadius(16)
      .margin({ right: 10 })
      .onClick(() => {
        this.period = key;
        this.load();
      })
  }

  /** 单个指标。值与标签同上，注重视觉重量而非附加说明 */
  @Builder
  metric(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(AppSize.SUBTITLE_FONT)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.TEXT)
      Text(label)
        .fontSize(AppSize.SMALL_FONT)
        .fontColor(AppColor.TEXT_3)
        .margin({ top: 4 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }
}
