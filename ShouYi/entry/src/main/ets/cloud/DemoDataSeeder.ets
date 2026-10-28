/**
 * @file    DemoDataSeeder.ets
 * @brief   演示数据种子 —— 给真实数据垫底，不抢真实数据的位置
 *
 * 为什么需要它：
 *   华为云 IoTDA 只提供「设备影子」（最近一次上报的属性快照），
 *   没有活动统计、告警历史、安全日志这些业务数据。App 端只能靠自己在线时
 *   逐次累加，于是刚装机、或者板子离线时，活动报告 / 热力图 / 预警中心
 *   全是空的 —— 截图和答辩演示都没法看。
 *
 * 设计原则（重要）：
 *   1. **只补缺口，不覆盖**：落库走 IotDaLocalStore 的 mergeXxx 系列，
 *      已存在的日期 / 格子 / 告警一律跳过。真实数据永远优先。
 *   2. **确定性**：随机数由日期派生，同一天反复生成结果完全一致，
 *      截图可复现，不会刷新一次变一个样。
 *   3. **幂等**：重复调用不会叠加，重装 App 会重新种一份。
 *   4. **可关闭**：由 IotDaConfig.DEMO_MODE 控制，关掉后只显示真实数据。
 *
 * 数据深度：
 *   日汇总 60 天 = 本期 30 + 上期 30，月报的「较上月」才有分母；
 *   小时分布 30 天，正好铺满月报热力图的 30 行。
 */

import { IotDaLocalStore } from './IotDaLocalStore';
import { Alert, AlertHandle, SafetyLogEntry } from '../model/Alert';
import { ActivityDaily, HeatmapCell } from '../model/ActivityRecord';
import {
  AlertType, AlertLevel, AlertStatus, HandleResult, MemberRole
} from '../common/constants/AppConstants';
import { DateUtil } from '../common/utils/DateUtil';
import { Logger } from '../common/utils/Logger';

export class DemoDataSeeder {
  private static readonly MODULE: string = 'DemoDataSeeder';

  /** 日汇总天数：60 = 本期 30 + 上期 30，月报同比才有分母 */
  static readonly SEED_DAYS: number = 60;

  /** 小时分布天数：月报热力图按日画行，少一天就空一行 */
  static readonly HOURLY_DAYS: number = 30;

  /**
   * 24 小时活动权重，按独居老人的真实作息建模：
   *   0-5 点睡眠几乎无活动；6-11 点起床、早饭、打扫最活跃；
   *   12-13 点午休；14-20 点下午活动；22 点后入睡。
   * 这套权重和 MockCloudAdapter 里的保持一致 —— 两条链路
   * 生成出来的图必须长得一样，否则演示时换个适配器就是另一种作息。
   */
  static readonly HOUR_WEIGHT: number[] = [
    0.1, 0.0, 0.0, 0.0, 0.0, 0.3,
    1.6, 2.4, 2.6, 2.2, 2.0, 1.8,
    0.5, 0.6, 1.8, 2.0, 1.9, 1.7,
    1.9, 2.1, 1.6, 0.9, 0.4, 0.2
  ];

  /** 权重查询，供报告页按小时拆分时复用 */
  static hourWeight(h: number): number {
    if (h < 0 || h >= DemoDataSeeder.HOUR_WEIGHT.length) {
      return 0;
    }
    return DemoDataSeeder.HOUR_WEIGHT[h];
  }

  /**
   * 按日期取 24 小时的活动次数（确定性，同一日期永远同一组数）。
   *
   * 供报表在演示模式下补全「今天」那一行用：板子上报慢，今天的热力图
   * 常常只有一两个格子，最后一行整片空白。这里按种子作息补齐已过去的小时。
   *
   * @param date yyyy-MM-dd
   */
  static hourlyOf(date: string): number[] {
    const parts: string[] = date.split('-');
    if (parts.length !== 3) {
      return new Array<number>(24).fill(0);
    }
    const dayTs: number = new Date(Number.parseInt(parts[0], 10),
      Number.parseInt(parts[1], 10) - 1, Number.parseInt(parts[2], 10)).getTime();
    const todayTs: number = DateUtil.startOfDay(DateUtil.now());
    const daysAgo: number = Math.max(0, Math.round((todayTs - dayTs) / 86400000));
    return DemoDataSeeder.countsOf(dayTs, daysAgo);
  }

  /**
   * 种入演示数据。可重复调用，已存在的数据不会被改动。
   *
   * @param store      IotDaLocalStore 实例（必须已 init）
   * @param deviceId   设备 ID，写进每条记录
   * @param deviceName 设备名，写进告警文案
   */
  static seed(store: IotDaLocalStore, deviceId: string, deviceName: string): void {
    if (!store.isReady()) {
      Logger.warn(DemoDataSeeder.MODULE, '本地存储未初始化，跳过演示数据种子');
      return;
    }

    const daily: ActivityDaily[] = DemoDataSeeder.buildDaily(deviceId);
    const hourly: HeatmapCell[] = DemoDataSeeder.buildHourly(deviceId);
    const alerts: Alert[] = DemoDataSeeder.buildAlerts(deviceId, deviceName);
    const logs: SafetyLogEntry[] = DemoDataSeeder.buildLogs(alerts);

    const dAdd: number = store.mergeDaily(daily);
    const hAdd: number = store.mergeHourly(hourly);
    const aAdd: number = store.mergeAlerts(alerts);
    const lAdd: number = store.mergeLogs(logs);

    Logger.info(DemoDataSeeder.MODULE,
      `演示数据种子：日汇总 +${dAdd}/${daily.length}，小时格 +${hAdd}/${hourly.length}，`
        + `告警 +${aAdd}/${alerts.length}，日志 +${lAdd}/${logs.length}`);
  }

  // ==================== 活动统计 ====================

  /**
   * 生成某一天 24 小时的活动次数。
   *
   * 随机数由「日期 + 小时」派生，不用 Math.random()：
   * 同一天无论生成几次结果都一样，截图和录屏不会互相打架。
   *
   * @param dayTs    当天零点时间戳
   * @param daysAgo  距今天数（0 = 今天），用于做「最近几天略降」的演示效果
   */
  private static countsOf(dayTs: number, daysAgo: number): number[] {
    const daySeed: number = Math.floor(dayTs / 86400000) % 97;
    // 最近 3 天刻意压低 22%：让「规律变化提示」能被触发，
    // 演示时能看到智能研判真的在判断，而不是永远显示"作息稳定"。
    const declineFactor: number = daysAgo <= 2 ? 0.78 : 1.0;
    const baseFactor: number = 0.85 + (daySeed % 30) / 100;

    const out: number[] = [];
    for (let h: number = 0; h < 24; h++) {
      const w: number = DemoDataSeeder.HOUR_WEIGHT[h] * baseFactor * declineFactor;
      const c: number = Math.max(0, Math.round(w + ((daySeed * (h + 7)) % 3) - 1));
      out.push(c);
    }
    return out;
  }

  private static buildDaily(deviceId: string): ActivityDaily[] {
    const out: ActivityDaily[] = [];
    const today: number = DateUtil.now();

    for (let d: number = DemoDataSeeder.SEED_DAYS - 1; d >= 0; d--) {
      const dayTs: number = DateUtil.startOfDay(today - d * 86400000);
      const counts: number[] = DemoDataSeeder.countsOf(dayTs, d);

      const daily: ActivityDaily = new ActivityDaily();
      daily.deviceId = deviceId;
      daily.date = DateUtil.formatDate(dayTs);
      daily.dayStart = dayTs;

      let total: number = 0;
      let activeHours: number = 0;
      let nightCount: number = 0;
      let firstActivity: number = 0;
      let lastActivity: number = 0;

      for (let h: number = 0; h < 24; h++) {
        const c: number = counts[h];
        if (c <= 0) {
          continue;
        }
        total = total + c;
        activeHours = activeHours + 1;
        const ts: number = dayTs + h * 3600000 + (h * 7 % 50) * 60000;
        if (firstActivity === 0) {
          firstActivity = ts;
        }
        lastActivity = ts;
        if (h >= 22 || h < 6) {
          nightCount = nightCount + c;
        }
      }

      daily.totalCount = total;
      daily.activeHours = activeHours;
      daily.firstActivity = firstActivity;
      daily.lastActivity = lastActivity;
      daily.nightCount = nightCount;
      out.push(daily);
    }
    return out;
  }

  private static buildHourly(deviceId: string): HeatmapCell[] {
    const out: HeatmapCell[] = [];
    const today: number = DateUtil.now();

    for (let d: number = DemoDataSeeder.HOURLY_DAYS - 1; d >= 0; d--) {
      const dayTs: number = DateUtil.startOfDay(today - d * 86400000);
      const date: string = DateUtil.formatDate(dayTs);
      const counts: number[] = DemoDataSeeder.countsOf(dayTs, d);
      for (let h: number = 0; h < 24; h++) {
        if (counts[h] <= 0) {
          continue;
        }
        const cell: HeatmapCell = new HeatmapCell();
        cell.date = date;
        cell.hour = h;
        cell.count = counts[h];
        out.push(cell);
      }
    }
    return out;
  }

  // ==================== 告警与安全日志 ====================

  /**
   * 告警历史：3 条待处置 + 6 条已闭环。
   *
   * 为什么要有待处置：首页主卡「有没有待处理」、Tab 角标、
   * 预警中心宫格「N 待处置」都要靠它，全是 0 的话整页没有信息量。
   * 为什么也要有已闭环：安全日志、处置时间线、误报反馈闭环
   * 这些能力只有已处置的告警才展示得出来。
   */
  private static buildAlerts(deviceId: string, deviceName: string): Alert[] {
    const now: number = DateUtil.now();
    const H: number = 3600000;
    const D: number = 86400000;
    const out: Alert[] = [];

    // ---------- 待处置 ----------
    out.push(DemoDataSeeder.makeAlert('demo_a01', deviceId, deviceName,
      AlertType.SOS_PRESSED, AlertLevel.P0, now - 2 * H - 20 * 60000, 1, 1,
      '老人按下紧急求助按钮，持续 5 秒未取消，已触发本地声光报警',
      AlertStatus.PENDING));

    out.push(DemoDataSeeder.makeAlert('demo_a02', deviceId, deviceName,
      AlertType.NO_ACTIVITY, AlertLevel.P1, now - 6 * H, 96, 60,
      '连续 96 分钟未检测到人体活动，超出该老人日常活动基线阈值',
      AlertStatus.PENDING));

    out.push(DemoDataSeeder.makeAlert('demo_a03', deviceId, deviceName,
      AlertType.TEMP_HUMIDITY_ABNORMAL, AlertLevel.P2, now - 1 * D - 3 * H, 33.6, 32,
      '室内温度 33.6℃ 持续 20 分钟，超出老人舒适区间',
      AlertStatus.PENDING));

    // ---------- 已闭环 ----------
    const a4: Alert = DemoDataSeeder.makeAlert('demo_a04', deviceId, deviceName,
      AlertType.GAS_LEAK, AlertLevel.P0, now - 3 * D - 5 * H, 620, 400,
      '燃气浓度 620 ppm 超出报警阈值，设备已联动声光报警',
      AlertStatus.HANDLED);
    DemoDataSeeder.attach(a4, '子女·张', MemberRole.CHILD,
      HandleResult.SELF_HANDLED, '远程确认阀门已关闭，开窗通风后浓度回落至 30 ppm', 8 * 60000, false);
    out.push(a4);

    const a5: Alert = DemoDataSeeder.makeAlert('demo_a05', deviceId, deviceName,
      AlertType.NO_ACTIVITY, AlertLevel.P1, now - 5 * D - 2 * H, 88, 60,
      '连续 88 分钟未检测到人体活动，超出该老人日常活动基线阈值',
      AlertStatus.HANDLED);
    DemoDataSeeder.attach(a5, '社区网格员·李', MemberRole.GRID_WORKER,
      HandleResult.GRID_WORKER, '网格员上门查看，老人在午睡，一切正常', 26 * 60000, false);
    out.push(a5);

    const a6: Alert = DemoDataSeeder.makeAlert('demo_a06', deviceId, deviceName,
      AlertType.DOOR_ABNORMAL, AlertLevel.P2, now - 6 * D - 7 * H, 1, 0,
      '门窗磁在 21:40 检测到开启，持续 35 分钟未关闭',
      AlertStatus.HANDLED);
    DemoDataSeeder.attach(a6, '子女·张', MemberRole.CHILD,
      HandleResult.ELDER_NORMAL, '电话确认老人外出散步，已按时回家', 15 * 60000, false);
    out.push(a6);

    const a7: Alert = DemoDataSeeder.makeAlert('demo_a07', deviceId, deviceName,
      AlertType.TEMP_HUMIDITY_ABNORMAL, AlertLevel.P2, now - 9 * D - 4 * H, 33.1, 32,
      '室内温度 33.1℃ 持续 20 分钟，超出老人舒适区间',
      AlertStatus.FALSE_ALARM);
    DemoDataSeeder.attach(a7, '子女·张', MemberRole.CHILD,
      HandleResult.FALSE_ALARM, '老人开了电暖器，属正常情况，已放宽温度阈值', 32 * 60000, true);
    out.push(a7);

    const a8: Alert = DemoDataSeeder.makeAlert('demo_a08', deviceId, deviceName,
      AlertType.LOW_BATTERY, AlertLevel.P3, now - 12 * D - 6 * H, 12, 15,
      '主机电池电量 12%，低于 15% 提示阈值',
      AlertStatus.HANDLED);
    DemoDataSeeder.attach(a8, '子女·张', MemberRole.CHILD,
      HandleResult.SELF_HANDLED, '已提醒老人更换电池，次日已充满', 45 * 60000, false);
    out.push(a8);

    const a9: Alert = DemoDataSeeder.makeAlert('demo_a09', deviceId, deviceName,
      AlertType.SOS_PRESSED, AlertLevel.P1, now - 15 * D - 2 * H, 1, 1,
      '老人按下紧急求助按钮，持续 5 秒未取消，已触发本地声光报警',
      AlertStatus.HANDLED);
    DemoDataSeeder.attach(a9, '物业值班·王', MemberRole.PROPERTY,
      HandleResult.PROPERTY, '物业上门确认，为误触，已提醒老人注意按键位置', 19 * 60000, false);
    out.push(a9);

    out.sort((a: Alert, b: Alert) => b.timestamp - a.timestamp);
    return out;
  }

  private static makeAlert(id: string, deviceId: string, deviceName: string,
    type: string, level: string, ts: number, value: number, threshold: number,
    desc: string, status: string): Alert {
    const a: Alert = new Alert();
    a.alertId = id;
    a.serverAlertId = `sa_${id}`;
    a.deviceId = deviceId;
    a.deviceName = deviceName;
    a.alertType = type;
    a.alertTypeName = AlertType.labelOf(type);
    a.level = level;
    a.timestamp = ts;
    a.triggerValue = value;
    a.threshold = threshold;
    a.description = desc;
    a.status = status;
    // 推送范围按等级走：P0 全员，P1 家属 + 网格员，P2 以下只通知家属。
    // 这不是编的，是 AppConstants 里定好的分级策略。
    a.notifiedRoles = level === AlertLevel.P0
      ? [MemberRole.CHILD, MemberRole.GRID_WORKER, MemberRole.PROPERTY]
      : (level === AlertLevel.P1
        ? [MemberRole.CHILD, MemberRole.GRID_WORKER]
        : [MemberRole.CHILD]);
    return a;
  }

  private static attach(a: Alert, handlerName: string, role: string,
    result: string, note: string, delayMs: number, adjusted: boolean): void {
    const h: AlertHandle = new AlertHandle();
    h.handlerName = handlerName;
    h.handlerRole = role;
    h.result = result;
    h.resultName = HandleResult.labelOf(result);
    h.note = note;
    h.handledAt = a.timestamp + delayMs;
    h.thresholdAdjusted = adjusted;
    a.handle = h;
  }

  /** 安全日志 = 已闭环告警的留痕，一条告警一条日志 */
  private static buildLogs(alerts: Alert[]): SafetyLogEntry[] {
    const out: SafetyLogEntry[] = [];
    for (const a of alerts) {
      const h: AlertHandle | undefined = a.handle;
      if (h === undefined) {
        continue;
      }
      const log: SafetyLogEntry = new SafetyLogEntry();
      log.logId = `log_${a.alertId}`;
      log.alertId = a.alertId;
      log.date = DateUtil.formatDate(a.timestamp);
      log.level = a.level;
      log.alertTypeName = a.alertTypeName;
      log.triggeredAt = a.timestamp;
      log.handledAt = h.handledAt;
      log.handlerName = h.handlerName;
      log.resultName = h.resultName;
      log.note = h.note;
      out.push(log);
    }
    return out;
  }
}
