import { Sensor } from '../model/Device';
import { Alert } from '../model/Alert';
import { DeviceStatusResp, ReadingsResp, ReadingsPoint } from '../cloud/CloudTypes';
import { CareService } from '../service/CareService';
import { TrendChart } from '../view/components/TrendChart';
import { TrendPoint } from '../model/ActivityRecord';
import { AppColor, AppSize } from '../common/constants/ThemeColors';
import { SensorType, SensorRisk, AlertType, AlertStatus } from '../common/constants/AppConstants';
import { DateUtil } from '../common/utils/DateUtil';
import { Logger } from '../common/utils/Logger';

import { ThemeMode, ThemeStore } from '../common/theme/ThemeStore';
/**
 * 跳转本页的传参类型，必须与发送端 DeviceOverviewPage 保持一致。
 * ArkTS 不允许无类型对象字面量，两边都用显式 class。
 */
class SensorDetailParams {
  sensorType: string = '';
}

/** 跳转告警详情页的传参，字段名与 pages/AlertDetail.ets 的接收端一致 */
class AlertDetailParams {
  alertId: string = '';

  constructor(alertId: string) {
    this.alertId = alertId;
  }
}

/** 时间范围选项 */
class RangeOption {
  key: string = '';
  label: string = '';

  constructor(key: string, label: string) {
    this.key = key;
    this.label = label;
  }
}

/**
 * 统计区的单格。
 *
 * 为什么要有这层 VM：@Builder 的值参数在 ArkUI 局部更新下不具响应性 ——
 * 首次渲染时 points 还是空的，之后异步加载完 points 变了，
 * 但 @Builder 不会重新求值，统计区会永远停在 "--"（实测踩坑）。
 * 改成 @State 数组 + ForEach（key 里带数值）才能跟着数据一起刷新。
 */
class StatVM {
  label: string = '';
  value: string = '';
}

/**
 * 传感器详情页 —— 单传感器的长期趋势。
 *
 * 从首页任意传感器卡片点击进入，回答一个问题：
 * "这个数字最近一直是这样吗，还是在往坏的方向走？"
 * 首页给的是当下，这一页给的是趋势，两者合起来才支撑"长期跟踪"。
 *
 * 入参：DeviceOverviewPage.openSensorDetail() 通过 pushUrl 传入 { sensorType }。
 */
@Entry
@Component
struct SensorDetail {

  /**
   * 订阅显示设置。@StorageProp 会在主题 / 关怀模式变化时触发本组件重渲染，
   * 这样 ThemeStore 一改，AppColor / AppSize 的 getter 重新取值，全页同步换肤。
   */
  @StorageProp('displayMode') displayMode: string = 'day';
  @StorageProp('careMode') careMode: boolean = false;
  private static readonly MODULE: string = 'SensorDetail';

  private static readonly RANGES: RangeOption[] = [
    new RangeOption('24h', '24 小时'),
    new RangeOption('7d', '7 天'),
    new RangeOption('30d', '30 天')
  ];

  @State sensorType: string = '';
  @State sensor: Sensor | undefined = undefined;
  @State points: TrendPoint[] = [];
  /**
   * 与该传感器相关的历史告警。
   *
   * 事件型传感器（SOS）的"历史数据"就是触发记录，普通传感器则是异常告警。
   * 两者在数据层是同一批数据，只是筛选的 alertType 不同，所以共用一条通道，
   * 由 alertTypesOf() 决定要哪几类。
   */
  @State relatedAlerts: Alert[] = [];
  /** 统计区三格，随趋势数据一起重算（见 StatVM 的说明） */
  @State stats: StatVM[] = [];
  @State rangeKey: string = '24h';
  @State loading: boolean = true;

  private service: CareService = new CareService();

  /**
   * 是否事件型传感器。
   * SOS 按钮是"按一下触发一次"的事件，没有连续量可言 ——
   * 给它画折线会得到一条恒零直线，那比不画更糟。
   */
  private isEventType(): boolean {
    return this.sensorType === SensorType.SOS_BUTTON;
  }

  aboutToAppear(): void {
    const params = this.getUIContext().getRouter().getParams() as SensorDetailParams;
    if (params !== undefined && params.sensorType !== undefined && params.sensorType.length > 0) {
      this.sensorType = params.sensorType;
    }
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    try {
      const resp: DeviceStatusResp | undefined = await this.service.loadDeviceStatus('');
      if (resp !== undefined) {
        this.sensor = resp.sensors.find((s: Sensor) => s.sensorType === this.sensorType);
      }
      // 告警与趋势互不依赖，两类传感器都要拉：趋势看"一直怎样"，
      // 告警看"有没有出过事"，缺一块信息就不完整。
      await this.loadRelatedAlerts();
      if (!this.isEventType()) {
        await this.loadTrend();
      }
    } catch (err) {
      Logger.error(SensorDetail.MODULE, `加载失败: ${(err as Error).message}`);
    } finally {
      this.loading = false;
    }
  }

  /**
   * 拉取最近 30 天里与当前传感器相关的告警。
   *
   * 过滤放在客户端而不是查询里：CloudAdapter 的 getAlerts 只接受
   * status / level 两个筛选维度，没有 alertType 参数。
   * 30 天窗口本身已经很小（演示环境十几条），本地过滤成本可以忽略。
   */
  async loadRelatedAlerts(): Promise<void> {
    try {
      const all: Alert[] = await this.service.loadAlerts('', '', 30);
      const types: string[] = this.alertTypesOf(this.sensorType);
      this.relatedAlerts = all
        .filter((a: Alert) => types.indexOf(a.alertType) >= 0)
        .sort((a: Alert, b: Alert) => b.timestamp - a.timestamp);
    } catch (err) {
      Logger.error(SensorDetail.MODULE, `加载相关告警失败: ${(err as Error).message}`);
      this.relatedAlerts = [];
    }
  }

  /**
   * 传感器类型 → 告警类型。
   *
   * 返回数组而不是单值：同一个物理传感器可能对应多条告警口径
   * （温湿度既是"温湿度异常"，也参与"设备离线"），
   * 数组形式以后加口径不用改调用方。
   */
  private alertTypesOf(sensorType: string): string[] {
    switch (sensorType) {
      case SensorType.PIR:
        return [AlertType.NO_ACTIVITY];
      case SensorType.DOOR:
        return [AlertType.DOOR_ABNORMAL];
      case SensorType.TEMP_HUMIDITY:
        return [AlertType.TEMP_HUMIDITY_ABNORMAL];
      case SensorType.SMOKE:
        return [AlertType.SMOKE_DETECTED];
      case SensorType.GAS:
        return [AlertType.GAS_LEAK];
      case SensorType.SOS_BUTTON:
        return [AlertType.SOS_PRESSED];
      default:
        // 心率没有独立的告警口径，走"长时间无活动"这类间接判断
        return [];
    }
  }

  /** 按所选时间范围拉取读数，转成折线图数据 */
  async loadTrend(): Promise<void> {
    const now: number = DateUtil.now();
    const resp: ReadingsResp | undefined = await this.service.loadReadings(
      this.sensorType, this.rangeFrom(now), now, this.rangeInterval());
    if (resp === undefined) {
      this.points = [];
      this.stats = this.buildStats();
      return;
    }
    const hourly: boolean = this.rangeKey === '24h';
    this.points = resp.points.map((p: ReadingsPoint) => {
      const label: string = hourly
        ? DateUtil.formatTime(p.timestamp)
        : DateUtil.formatShortDate(p.timestamp);
      return { date: label, count: p.value } as TrendPoint;
    });
    // 统计量与曲线同批算好再一起提交，避免出现"图有了、数字还是 --"的中间态
    this.stats = this.buildStats();
  }

  /**
   * 统计区三格。
   *
   * 开关量传感器（门窗 / 人体活动）单独一套口径：它们的值是 0/1，
   * 算出来的"平均 0.16"对家属没有任何意义 —— 想知道的是
   * 开了几次、活动的时间占多少。所以按类型分派口径。
   */
  private buildStats(): StatVM[] {
    if (this.isBoolType()) {
      const word: string = this.sensorType === SensorType.PIR ? '活动' : '开启';
      // 30 天走日聚合，每个点代表一整天，"次数"的说法在这里不成立 ——
      // 一个桶里的跃变只是"这几天开过"，说成"天数"才不误导
      const daily: boolean = this.rangeKey === '30d';
      // 人体活动的读数本身就是"这个小时有没有人动"，连续几个小时都算
      // 同一段活动。叫「活动次数」会被理解成抬了几次手，说「活动时段」才对。
      let countLabel: string = `${word}次数`;
      if (daily) {
        countLabel = `${word}天数`;
      } else if (this.sensorType === SensorType.PIR) {
        countLabel = '活动时段';
      }
      return [
        this.mkStat(countLabel, this.boolOnCount()),
        this.mkStat(daily ? '天数占比' : `${word}占比`, this.boolOnRatio()),
        this.mkStat('当前状态', this.boolCurrent())
      ];
    }
    return [
      this.mkStat('平均', this.avgText()),
      this.mkStat('最高', this.maxText()),
      this.mkStat('最低', this.minText())
    ];
  }

  private mkStat(label: string, value: string): StatVM {
    const s: StatVM = new StatVM();
    s.label = label;
    s.value = value;
    return s;
  }

  /**
   * 是否开关量传感器。
   * 这两类的读数只有 0 和 1，Y 轴、统计口径、基线都要区别对待。
   */
  private isBoolType(): boolean {
    return this.sensorType === SensorType.DOOR || this.sensorType === SensorType.PIR;
  }

  /**
   * 开关量 Y 轴两端标签。
   *
   * 30 天是日聚合，一个点代表一整天 —— 这时写「开」会被读成
   * "门一直敞着"，写「有」才是"这天有过开合/活动"。
   */
  private boolLabel(on: boolean): string {
    if (this.rangeKey === '30d') {
      return on ? '有' : '无';
    }
    if (this.sensorType === SensorType.PIR) {
      return on ? '动' : '静';
    }
    return on ? '开' : '关';
  }

  /**
   * 开关量：统计窗口内"从无到有"的跃变次数。
   *
   * 阈值用 > 0 而不是 > 0.5：7 天 / 30 天走日聚合，服务端返回的是当天均值，
   * 一天开过一小时就是 0.04，用 0.5 判会把整天都算成"没开过"。
   */
  private boolOnCount(): string {
    if (this.points.length === 0) {
      return '--';
    }
    // 日聚合：每个点是一整天，直接数"有过开合的天数"。
    // 这时不能数跃变 —— 一个桶里只可能有一个值，跃变数会退化成 1。
    if (this.rangeKey === '30d') {
      let days: number = 0;
      for (const p of this.points) {
        if (p.count > 0) {
          days++;
        }
      }
      return `${days} 天`;
    }
    let count: number = 0;
    let prevOn: boolean = this.points[0].count > 0;
    if (prevOn) {
      count++;
    }
    for (let i = 1; i < this.points.length; i++) {
      const on: boolean = this.points[i].count > 0;
      if (on && !prevOn) {
        count++;
      }
      prevOn = on;
    }
    return `${count} 次`;
  }

  /** 开关量：处于"开/有人"状态的时间格占比。阈值同 boolOnCount */
  private boolOnRatio(): string {
    if (this.points.length === 0) {
      return '--';
    }
    let on: number = 0;
    for (const p of this.points) {
      if (p.count > 0) {
        on++;
      }
    }
    return `${Math.round(on / this.points.length * 100)}%`;
  }

  /** 开关量：当前这一格是开还是关 */
  private boolCurrent(): string {
    if (this.sensor === undefined) {
      return '--';
    }
    const on: boolean = this.sensor.value > 0.5;
    if (this.sensorType === SensorType.PIR) {
      return on ? '有活动' : '无活动';
    }
    return on ? '开启' : '已关闭';
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
        // ---------- 顶部导航 ----------
        Row() {
          // 返回区做成 40×40 的方块：单个「‹」字只有 10 来像素宽，
          // 老人和家属都容易点不中，必须把热区放大到标准可点尺寸
          Text('‹')
            .fontSize(28)
            .fontColor(AppColor.TEXT)
            .width(40)
            .height(40)
            .textAlign(TextAlign.Center)
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })
          Text(this.titleOf(this.sensorType))
            .fontSize(AppSize.TITLE_FONT)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.TEXT)
            .layoutWeight(1)
          if (this.sensor !== undefined) {
            Text(this.sensor.statusLabel())
              .fontSize(AppSize.SMALL_FONT)
              .fontColor(AppColor.statusColor(this.sensor.status()))
              .border({ width: 1, color: AppColor.statusBorder(this.sensor.status()) })
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(10)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding(AppSize.PAGE_PADDING)

        Scroll() {
          Column() {
            // ---------- 当前值 ----------
            Column() {
              Text('当前读数')
                .fontSize(AppSize.SMALL_FONT)
                .fontColor(AppColor.TEXT_3)
                .width('100%')

              Row() {
                Text(this.currentValueText())
                  .fontSize(22)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.sensor !== undefined
                    ? AppColor.statusTextColor(this.sensor.status()) : AppColor.TEXT_3)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)

                Row()
                  .width(10)
                  .height(10)
                  .borderRadius(5)
                  .backgroundColor(this.sensor !== undefined
                    ? AppColor.statusColor(this.sensor.status()) : AppColor.TEXT_3)
                  .margin({ left: 10 })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .margin({ top: 8 })

              Text(this.updateText())
                .fontSize(AppSize.SMALL_FONT)
                .fontColor(AppColor.TEXT_3)
                .margin({ top: 8 })
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(AppColor.CARD)
            .borderRadius(AppSize.CARD_RADIUS)
            .margin({ bottom: 12 })

            // ---------- 历史数据 ----------
            // 连续量传感器给趋势线与统计量；事件型传感器（SOS）给触发记录。
            if (!this.isEventType()) {
              Column() {
                Row() {
                  Text('长期趋势')
                    .fontSize(AppSize.SUBTITLE_FONT)
                    .fontWeight(FontWeight.Bold)
                    .fontColor(AppColor.TEXT)
                    .layoutWeight(1)
                  Text(this.rangeLabel())
                    .fontSize(AppSize.SMALL_FONT)
                    .fontColor(AppColor.TEXT_3)
                }
                .width('100%')
                .margin({ bottom: 12 })

                Row() {
                  ForEach(SensorDetail.RANGES, (r: RangeOption) => {
                    this.rangeChip(r)
                  }, (r: RangeOption) => r.key)
                }
                .width('100%')
                .margin({ bottom: 14 })

                // 开关量（门窗 / 人体活动）：Y 轴固定「关·开 / 静·动」两档，
                // 也不画均值基线 —— 一条 0.16 的虚线在开关图上会被误读成阈值
                TrendChart({
                  points: this.points,
                  chartWidth: 296,
                  chartHeight: 168,
                  boolAxis: this.isBoolType(),
                  boolOffLabel: this.boolLabel(false),
                  boolOnLabel: this.boolLabel(true),
                  showBaseline: !this.isBoolType()
                })

                // ---------- 统计量 ----------
                // key 带数值：只用 label 的话 ArkUI 判定"同一条目"复用节点，
                // 切时间范围后数字不刷新
                Row() {
                  ForEach(this.stats, (s: StatVM) => {
                    Column() {
                      Text(s.value)
                        .fontSize(AppSize.CAPTION_FONT)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(AppColor.TEXT)
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                      Text(s.label)
                        .fontSize(AppSize.SMALL_FONT)
                        .fontColor(AppColor.TEXT_3)
                        .margin({ top: 4 })
                        .maxLines(1)
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                  }, (s: StatVM) => `${s.label}_${s.value}`)
                }
                .width('100%')
                .margin({ top: 14 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(16)
              .backgroundColor(AppColor.CARD)
              .borderRadius(AppSize.CARD_RADIUS)
              .margin({ bottom: 12 })

              // 趋势回答"平时是什么样"，告警回答"有没有出过事"
              this.alertCard()
            } else {
              this.eventCard()
            }

            // ---------- 说明 ----------
            Column() {
              Text('关于这项监测')
                .fontSize(AppSize.SUBTITLE_FONT)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.TEXT)
                .width('100%')
              Text(this.descOf(this.sensorType))
                .fontSize(AppSize.SMALL_FONT)
                .fontColor(AppColor.TEXT_3)
                .lineHeight(20)
                .margin({ top: 8 })
                .width('100%')
              Text(this.riskNote())
                .fontSize(AppSize.SMALL_FONT)
                .fontColor(SensorRisk.isHighRisk(this.sensorType) ? AppColor.DANGER : AppColor.TEXT_2)
                .lineHeight(20)
                .margin({ top: 8 })
                .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(AppColor.CARD)
            .borderRadius(AppSize.CARD_RADIUS)

            Blank().height(20)
          }
          .width('100%')
          .padding({ left: AppSize.PAGE_PADDING, right: AppSize.PAGE_PADDING })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(AppColor.BG)

  }


  @Builder
  rangeChip(r: RangeOption) {
    Text(r.label)
      .fontSize(AppSize.SMALL_FONT)
      .fontColor(this.rangeKey === r.key ? AppColor.ON_PRIMARY: AppColor.TEXT_2)
      .backgroundColor(this.rangeKey === r.key ? AppColor.PRIMARY : AppColor.SURFACE)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(14)
      .margin({ right: 8 })
      .onClick(() => {
        if (this.rangeKey !== r.key) {
          this.rangeKey = r.key;
          this.loadTrend();
        }
      })
  }

  /**
   * 事件型传感器的历史数据卡 —— 触发记录。
   *
   * SOS 按钮是事件，没有连续量：硬画折线只会得到一条恒零直线，
   * 那比不画更糟 —— 家属会以为页面坏了。列出每一次触发的时间与状态
   * 才是真正有用的历史数据。
   * 没有触发时也要给明确空状态：家属需要的是"没事"这个确定答案，
   * 而不是一片空白。
   */
  @Builder
  eventCard() {
    Column() {
      Row() {
        Text('触发记录')
          .fontSize(AppSize.SUBTITLE_FONT)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .layoutWeight(1)
        Text('近 30 天')
          .fontSize(AppSize.SMALL_FONT)
          .fontColor(AppColor.TEXT_3)
      }
      .width('100%')
      .margin({ bottom: 4 })

      if (this.relatedAlerts.length === 0) {
        Text('近 30 天没有求助触发记录 · 老人未按下求助按钮')
          .fontSize(AppSize.SMALL_FONT)
          .fontColor(AppColor.TEXT_3)
          .lineHeight(20)
          .padding({ top: 24, bottom: 24 })
          .width('100%')
      } else {
        ForEach(this.relatedAlerts, (a: Alert) => {
          Column() {
            Row() {
              Text(a.description.length > 0 ? a.description : '老人按下紧急求助按钮')
                .fontSize(AppSize.CAPTION_FONT)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.TEXT)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .layoutWeight(1)
              // 状态色按实际状态走：SOS 本身是最高优先级，
              // 但「已处置」还挂红色会让整页看起来像一直在报警
              Text(AlertStatus.labelOf(a.status))
                .fontSize(10)
                .fontColor(this.alertStatusColor(a.status))
                .border({ width: 1, color: this.alertStatusColor(a.status) })
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(3)
                .margin({ left: 8 })
            }
            .width('100%')

            Text(DateUtil.format(a.timestamp))
              .fontSize(AppSize.SMALL_FONT)
              .fontColor(AppColor.TEXT_3)
              .margin({ top: 4 })
              .width('100%')
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .border({ width: { bottom: 1 }, color: AppColor.LINE })
        }, (a: Alert) => a.alertId)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(AppColor.CARD)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ bottom: 12 })
  }

  /**
   * 相关告警卡 —— 普通传感器的"出过什么事"。
   *
   * 趋势图回答"平时是什么样"，这张卡回答"有没有出过事"。
   * 家属点进来看某项监测，真正想确认的是这两件事，缺一件都答不完整。
   *
   * 空状态必须给明确文案：这一页本来就是来确认安全的，
   * 一片空白会被读成"没加载出来"，而不是"没有告警"。
   */
  @Builder
  alertCard() {
    Column() {
      Row() {
        Text('相关告警')
          .fontSize(AppSize.SUBTITLE_FONT)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.TEXT)
          .layoutWeight(1)
        Text('近 30 天')
          .fontSize(AppSize.SMALL_FONT)
          .fontColor(AppColor.TEXT_3)
      }
      .width('100%')
      .margin({ bottom: 4 })

      if (this.relatedAlerts.length === 0) {
        Text(this.emptyAlertText())
          .fontSize(AppSize.SMALL_FONT)
          .fontColor(AppColor.TEXT_3)
          .lineHeight(20)
          .padding({ top: 20, bottom: 20 })
          .width('100%')
      } else {
        ForEach(this.relatedAlerts, (a: Alert) => {
          Column() {
            Row() {
              Text(AlertType.labelOf(a.alertType))
                .fontSize(AppSize.CAPTION_FONT)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.TEXT)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(AlertStatus.labelOf(a.status))
                .fontSize(10)
                .fontColor(this.alertStatusColor(a.status))
                .border({ width: 1, color: this.alertStatusColor(a.status) })
                .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                .borderRadius(3)
                .margin({ left: 8 })
            }
            .width('100%')

            Text(DateUtil.format(a.timestamp))
              .fontSize(AppSize.SMALL_FONT)
              .fontColor(AppColor.TEXT_3)
              .margin({ top: 4 })
              .width('100%')
          }
          .width('100%')
          .padding({ top: 12, bottom: 12 })
          .border({ width: { bottom: 1 }, color: AppColor.LINE })
          .onClick(() => {
            this.openAlertDetail(a);
          })
        }, (a: Alert) => a.alertId)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(16)
    .backgroundColor(AppColor.CARD)
    .borderRadius(AppSize.CARD_RADIUS)
    .margin({ bottom: 12 })
  }

  /** 告警状态色：未处置用红、已确认用黄、已处置用灰 */
  private alertStatusColor(status: string): string {
    if (status === AlertStatus.PENDING) {
      return AppColor.DANGER;
    }
    if (status === AlertStatus.CONFIRMED) {
      return AppColor.WARNING;
    }
    return AppColor.TEXT_3;
  }

  /** 空状态文案：按传感器类型给具体说法，不用"暂无数据"糊过去 */
  private emptyAlertText(): string {
    switch (this.sensorType) {
      case SensorType.DOOR:
        return '近 30 天门窗未出现长时间敞开 · 无相关告警';
      case SensorType.TEMP_HUMIDITY:
        return '近 30 天室内温湿度未超出舒适区间 · 无相关告警';
      case SensorType.SMOKE:
        return '近 30 天烟雾浓度未触发阈值 · 无相关告警';
      case SensorType.GAS:
        return '近 30 天可燃气体浓度未触发阈值 · 无相关告警';
      case SensorType.PIR:
        return '近 30 天没有出现长时间无活动 · 无相关告警';
      default:
        return '近 30 天无相关告警记录';
    }
  }

  /** 打开某条告警的完整详情（时间线 + 处置闭环） */
  private openAlertDetail(alert: Alert): void {
    const params: AlertDetailParams = new AlertDetailParams(alert.alertId);
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/AlertDetail',
      params: params
    }).catch((e: Error) => {
      Logger.warn(SensorDetail.MODULE, `跳转告警详情失败: ${e.message}`);
    });
  }

  // ==================== 取值辅助 ====================

  private rangeFrom(now: number): number {
    if (this.rangeKey === '30d') {
      return now - 30 * 86400000;
    }
    if (this.rangeKey === '7d') {
      return now - 7 * 86400000;
    }
    return now - 24 * 3600000;
  }

  /** 30 天用日聚合，其余用小时聚合，避免点位过密 */
  private rangeInterval(): string {
    return this.rangeKey === '30d' ? '1d' : '1h';
  }

  private rangeLabel(): string {
    if (this.rangeKey === '30d') {
      return '最近 30 天';
    }
    if (this.rangeKey === '7d') {
      return '最近 7 天';
    }
    return '最近 24 小时';
  }

  private currentValueText(): string {
    if (this.sensor === undefined) {
      return '--';
    }
    // 离线时同样给 "--"，不展示不可信的缓存值
    if (!this.sensor.online) {
      return '--';
    }
    // SOS 按钮的"读数"是它自己的状态。数据层给的是「正常」，
    // 放在「当前读数」标题下会读成"这一项监测正常"，
    // 改成「待命中」才说得清是按钮在待命。
    if (this.sensorType === SensorType.SOS_BUTTON) {
      return this.sensor.value > 0.5 ? '已按下' : '待命中';
    }
    return this.sensor.displayValue.length > 0 ? this.sensor.displayValue : '--';
  }

  private updateText(): string {
    if (this.sensor === undefined) {
      return '暂无数据';
    }
    if (!this.sensor.online) {
      return '设备离线，暂无实时读数';
    }
    const t: number = this.sensor.updatedAt > 0 ? this.sensor.updatedAt : this.sensor.lastChanged;
    return t > 0 ? `最后更新：${DateUtil.relative(t)}` : '最后更新：刚刚';
  }

  private avgText(): string {
    if (this.points.length === 0) {
      return '--';
    }
    let sum: number = 0;
    for (const p of this.points) {
      sum += p.count;
    }
    return this.withUnit(Math.round(sum / this.points.length * 10) / 10);
  }

  private maxText(): string {
    if (this.points.length === 0) {
      return '--';
    }
    let m: number = this.points[0].count;
    for (const p of this.points) {
      m = Math.max(m, p.count);
    }
    return this.withUnit(Math.round(m * 10) / 10);
  }

  private minText(): string {
    if (this.points.length === 0) {
      return '--';
    }
    let m: number = this.points[0].count;
    for (const p of this.points) {
      m = Math.min(m, p.count);
    }
    return this.withUnit(Math.round(m * 10) / 10);
  }

  private withUnit(v: number): string {
    const u: string = this.unitOf(this.sensorType);
    return u.length > 0 ? `${v}${u}` : `${v}`;
  }

  private unitOf(type: string): string {
    switch (type) {
      case SensorType.TEMP_HUMIDITY:
        return '℃';
      case SensorType.PIR:
        return ' 次';
      case SensorType.SMOKE:
      case SensorType.GAS:
        return ' ppm';
      default:
        return '';
    }
  }

  private titleOf(type: string): string {
    switch (type) {
      case SensorType.PIR:
        return '人体活动';
      case SensorType.DOOR:
        return '门窗状态';
      case SensorType.TEMP_HUMIDITY:
        return '温湿度';
      case SensorType.SMOKE:
        return '烟雾监测';
      case SensorType.GAS:
        return '燃气监测';
      case SensorType.SOS_BUTTON:
        return '紧急求助按钮';
      case SensorType.HEART_RATE:
        return '心率';
      default:
        return '传感器详情';
    }
  }

  private descOf(type: string): string {
    switch (type) {
      case SensorType.PIR:
        return '红外人体感应，记录老人在家的活动频次。白天长时间无活动、'
          + '或夜间超过阈值没有活动，会触发预警。';
      case SensorType.DOOR:
        return '门窗磁感应，记录开合状态与持续时长。长时间敞开会被判为待关注，'
          + '提醒家属确认老人是否安全。';
      case SensorType.TEMP_HUMIDITY:
        return '室内温湿度监测。超出舒适区间会先给黄色提醒，'
          + '用于预防中暑与着凉，不直接升级为高危。';
      case SensorType.SMOKE:
        return '烟雾浓度监测。属于高危类传感器，一旦超过阈值直接进入红色告警，'
          + '并以最高优先级推送给全部家属。';
      case SensorType.GAS:
        return '可燃气体浓度监测。属于高危类传感器，一旦超过阈值直接进入红色告警，'
          + '同时触发设备端语音播报与声光报警。';
      case SensorType.SOS_BUTTON:
        return '老人随身佩戴的求助按钮。按下即触发本地声光报警与语音求助，'
          + '并推送全部家属 —— 这是整条链路上响应级别最高的动作。';
      case SensorType.HEART_RATE:
        return '由监护主机的毫米波雷达/PPG 采集的实时心率。'
          + '超出静息正常区间会提示关注。';
      default:
        return '该传感器的历史读数与趋势。';
    }
  }

  private riskNote(): string {
    if (SensorRisk.isHighRisk(this.sensorType)) {
      return `风险分级：高危 —— 异常直接进红色告警，走最高优先级推送。`;
    }
    return '风险分级：普通监测 —— 异常先给黄色提醒，由家属判断是否升级。';
  }
}
