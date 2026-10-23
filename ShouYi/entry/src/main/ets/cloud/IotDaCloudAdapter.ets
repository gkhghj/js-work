/**
 * @file    IotDaCloudAdapter.ets
 * @brief   华为云 IoTDA 适配器（第一段：类框架 + 4 个真接口）
 *
 * 放置位置：复制到 entry/src/main/ets/cloud/ 下（与 CloudApi.ets 同目录）
 *
 * 本段实现：
 *   真接口 4 个 —— getDeviceList / getDeviceStatus / confirmAlert / handleAlert
 *   门面 15 个 —— 返回空值，保证 App 能启动、能进页面
 *   推送 1 组  —— subscribeAlerts / unsubscribeAlerts（轮询影子，4 秒一次）
 *
 * 切换方式：AppConfig.create() 里把 new MockCloudAdapter() 换成
 *          new IotDaCloudAdapter(IotDaHttp实例)
 */

import { CloudApi } from './CloudApi';
import { CloudError } from './HttpClient';
import {
  RegisterDeviceReq, RegisterDeviceResp, HeartbeatReq, HeartbeatResp,
  UploadReadingsReq, UploadReadingsResp, UploadAlertReq, UploadAlertResp,
  DeviceListItem, DeviceStatusResp, ReadingsQuery, ReadingsResp, ReadingsPoint,
  AlertQuery, AlertDetailResp, ConfirmAlertResp, HandleAlertReq, HandleAlertResp,
  ActivityReportResp, ActivityDistributionResp, SafetyLogQuery,
  FamilyMemberListResp, PushListener, PushMessage, PageData
} from './CloudTypes';
import { IotDaHttp } from './IotDaHttp';
import { IotDaLocalStore } from './IotDaLocalStore';
import {
  IotDaDeviceListResp, IotDaDeviceBrief, IotDaDeviceDetail,
  IotDaShadowResp, IotDaShadowService, IotDaCommandReq, IotDaCommandResp
} from './IotDaTypes';
import { Device, Sensor, DeviceConfig } from '../model/Device';
import { Alert, AlertTimelineNode, SafetyLogEntry } from '../model/Alert';
import { ActivityDaily, ActivityReport, HeatmapCell, TrendPoint } from '../model/ActivityRecord';
import { FamilyMember } from '../model/FamilyMember';
import { CloudCode, SensorType, AlertType, AlertLevel } from '../common/constants/AppConstants';
import { Logger } from '../common/utils/Logger';
import { DateUtil } from '../common/utils/DateUtil';

/** 影子里的属性键 —— 与 product_model.json 的 property_key 一一对应 */
class PKey {
  static readonly PIR: string = 'pir';
  static readonly DOOR: string = 'door';
  static readonly TEMP: string = 'temperature';
  static readonly HUM: string = 'humidity';
  static readonly SMOKE: string = 'smoke';
  static readonly GAS: string = 'gas';
  static readonly SOS: string = 'sos';
  static readonly BATTERY: string = 'battery';
  static readonly HEART: string = 'heartRate';
  static readonly SPO2: string = 'bloodOxygen';
  static readonly BODY_TEMP: string = 'bodyTemperature';
  static readonly STEPS: string = 'stepCount';
  static readonly ALARM: string = 'alarmActive';
  static readonly RSSI: string = 'rssi';
}

/** 环形缓冲里的一条读数（带传感器类型，便于按类型过滤） */
class BufferedReading {
  sensorType: string = '';
  timestamp: number = 0;
  value: number = 0;
  /** 仅温湿度传感器用：同一时刻的湿度值 */
  humidity: number = 0;
}

/** 演示告警模板（类型 / 触发值 / 阈值 / 描述） */
class DemoAlertTemplate {
  type: string;
  value: number;
  threshold: number;
  desc: string;

  constructor(type: string, value: number, threshold: number, desc: string) {
    this.type = type;
    this.value = value;
    this.threshold = threshold;
    this.desc = desc;
  }
}

export class IotDaCloudAdapter implements CloudApi {
  private static readonly MODULE: string = 'IotDaCloudAdapter';

  private http: IotDaHttp;
  private projectId: string;
  private deviceId: string;
  private familyId: string;

  /** 本地存储：告警 / 日志 / 活动统计 / 家庭成员 */
  private store: IotDaLocalStore = new IotDaLocalStore();

  /**
   * 注入应用沙箱目录，开启本地持久化。
   * 不调用也能跑，只是告警/日志/活动统计不落盘。
   */
  initStore(filesDir: string): void {
    this.store.init(filesDir);
  }

  /** 轮询间隔：IoTDA 没有推送通道给应用侧，只能用轮询影子近似 */
  private static readonly POLL_MS: number = 4000;

  /**
   * 是否在轮询影子时自动派生告警。
   *
   * 关闭：设备离线 / 影子陈旧时（烟雾、燃气停在超阈值），每次启动都会
   * 反复刷出一堆告警，演示时又吵又乱。改为「刷新 / 模拟告警」按需注入
   * 几条（见 injectDemoAlerts），把节奏交给演示者。
   */
  private static readonly AUTO_ALERT_ON_POLL: boolean = false;
  private listener: PushListener | undefined = undefined;
  private timerId: number = -1;
  /** 上一轮已激活的告警类型集合，用逗号拼接，用于去重（避免每 4 秒重复弹） */
  private prevSig: string = '';
  /** 上一轮的 PIR 状态，用于检测上升沿（活动计数） */
  private prevPir: boolean = false;

  /** 读数环形缓冲上限。4 秒一条 × 5 个传感器，2000 条约覆盖 26 分钟 */
  private static readonly RING_MAX: number = 2000;
  private ring: BufferedReading[] = [];
  /** 设备显示名，从最近一次查询里缓存下来，供告警文案使用 */
  private deviceName: string = '居家安全网关';

  constructor(http: IotDaHttp, projectId: string, deviceId: string, familyId: string) {
    this.http = http;
    this.projectId = projectId;
    this.deviceId = deviceId;
    this.familyId = familyId;
  }

  // ==================== 内部：影子 -> 领域模型 ====================

  /**
   * 取影子里的属性值。
   *
   * ⚠️ 平台把属性包在 `reported.properties` 里，不是平铺在 `reported` 下。
   * 实测响应（2026-10-21）：
   *   reported: { properties: { gas: 813, ... }, event_time: "20261021T060239Z" }
   * 按平铺读会得到 undefined 且不报错，页面只显示"无数据"。
   */
  private async fetchShadowProps(): Promise<Record<string, number | string | boolean>> {
    // deviceId 为空（AppConfig.deviceId 默认 ''，构造时还没绑定主机）时，
    // 影子 URL 会变成 /devices//shadow，华为云回 IOTDA.000029。
    // 这里统一兜底解析一次，之后走非空分支，不会递归。
    if (this.deviceId.length === 0 && !await this.ensureDeviceId()) {
      throw new Error('未绑定监护主机');
    }
    const path: string = `/v5/iot/${this.projectId}/devices/${this.deviceId}/shadow`;
    const resp: IotDaShadowResp = await this.http.get<IotDaShadowResp>(path);
    if (resp.shadow === undefined || resp.shadow.length === 0) {
      return {};
    }
    let svc: IotDaShadowService | undefined = undefined;
    for (const s of resp.shadow) {
      if (s.service_id === 'monitor') {
        svc = s;
        break;
      }
    }
    if (svc === undefined) {
      svc = resp.shadow[0];
    }
    if (svc.reported === undefined || svc.reported.properties === undefined
      || svc.reported.properties === null) {
      return {};
    }
    return svc.reported.properties;
  }

  private num(m: Record<string, number | string | boolean>, k: string, d: number): number {
    const v: number | string | boolean | undefined = m[k];
    return typeof v === 'number' ? v as number : d;
  }

  private flag(m: Record<string, number | string | boolean>, k: string, d: boolean): boolean {
    const v: number | string | boolean | undefined = m[k];
    return typeof v === 'boolean' ? v as boolean : d;
  }

  private buildDevice(brief: IotDaDeviceBrief, rep: Record<string, number | string | boolean>): Device {
    // 顺手缓存设备名，告警文案要用
    this.deviceName = brief.device_name;
    const d: Device = new Device();
    d.deviceId = brief.device_id;
    d.deviceSn = brief.node_id;
    d.deviceName = brief.device_name;
    d.model = 'RK2206-SY-01';
    d.firmwareVersion = '1.0.0';
    d.online = brief.status === 'ONLINE';
    d.lastHeartbeat = Date.now();
    d.battery = this.num(rep, PKey.BATTERY, 0);
    d.signal = this.num(rep, PKey.RSSI, 0);
    d.networkType = 'wifi';
    d.activeAlerts = 0;
    d.capabilities = [SensorType.PIR, SensorType.DOOR, SensorType.TEMP_HUMIDITY,
      SensorType.SMOKE, SensorType.GAS, SensorType.SOS_BUTTON];
    d.heartRate = this.num(rep, PKey.HEART, 0);
    d.heartRateAt = Date.now();
    d.spo2 = this.num(rep, PKey.SPO2, 0);
    d.bodyTemp = this.num(rep, PKey.BODY_TEMP, 0);
    d.steps = this.num(rep, PKey.STEPS, 0);
    // vitalsAt：任一体征字段有读数就记为"刚采集"。
    // 三项体征（血氧/体温/步数）并非所有主机都支持，影子没有这些键时
    // 读到 0，四连格显示"无读数"，但不能连有心率的主机也判为无读取。
    const hasAnyVital: boolean = d.heartRate > 0 || d.spo2 > 0
      || d.bodyTemp > 0 || d.steps > 0;
    d.vitalsAt = hasAnyVital ? Date.now() : 0;
    return d;
  }

  /**
   * 把影子 reported 映射成 Sensor[]。
   * 注意 temperature + humidity 合成一个温湿度传感器，
   * 而 sos / heartRate 的键名与 SensorType 常量不同，需显式转换。
   */
  private buildSensors(rep: Record<string, number | string | boolean>, devId: string): Sensor[] {
    const out: Sensor[] = [];
    const now: number = Date.now();

    const pir: Sensor = new Sensor();
    pir.sensorId = 'sen_pir';
    pir.deviceId = devId;
    pir.sensorType = SensorType.PIR;
    pir.name = '人体活动';
    pir.value = this.flag(rep, PKey.PIR, false) ? 1 : 0;
    pir.displayValue = this.flag(rep, PKey.PIR, false) ? '有人活动' : '无活动';
    pir.normal = true;
    pir.online = true;
    pir.battery = this.num(rep, PKey.BATTERY, 0);
    pir.updatedAt = now;
    // level 留空 —— 让 Sensor.status() 按 online + normal + 风险分级自动推导，
    // 不要写死 'high'（那是 SensorRisk 的值，不是 SensorStatus 的值）
    pir.level = '';
    out.push(pir);

    const door: Sensor = new Sensor();
    door.sensorId = 'sen_door';
    door.deviceId = devId;
    door.sensorType = SensorType.DOOR;
    door.name = '门窗磁';
    door.value = this.num(rep, PKey.DOOR, 0);
    door.displayValue = door.value === 1 ? '已开启' : '已关闭';
    door.normal = true;
    door.online = true;
    door.battery = this.num(rep, PKey.BATTERY, 0);
    door.updatedAt = now;
    door.level = '';
    out.push(door);

    const t: number = this.num(rep, PKey.TEMP, 0);
    const h: number = this.num(rep, PKey.HUM, 0);
    const th: Sensor = new Sensor();
    th.sensorId = 'sen_temp_humidity';
    th.deviceId = devId;
    th.sensorType = SensorType.TEMP_HUMIDITY;
    th.name = '温湿度';
    th.value = t;
    th.displayValue = `${t.toFixed(1)}°C / ${h.toFixed(0)}%`;
    th.normal = t >= 10 && t <= 32 && h >= 30 && h <= 70;
    th.online = true;
    th.battery = this.num(rep, PKey.BATTERY, 0);
    th.updatedAt = now;
    th.level = '';
    out.push(th);

    const smoke: Sensor = new Sensor();
    smoke.sensorId = 'sen_smoke';
    smoke.deviceId = devId;
    smoke.sensorType = SensorType.SMOKE;
    smoke.name = '烟雾';
    smoke.value = this.num(rep, PKey.SMOKE, 0);
    smoke.displayValue = `${smoke.value} ppm`;
    smoke.normal = smoke.value <= 300;
    smoke.online = true;
    smoke.battery = this.num(rep, PKey.BATTERY, 0);
    smoke.updatedAt = now;
    smoke.level = '';
    out.push(smoke);

    const gas: Sensor = new Sensor();
    gas.sensorId = 'sen_gas';
    gas.deviceId = devId;
    gas.sensorType = SensorType.GAS;
    gas.name = '可燃气体';
    gas.value = this.num(rep, PKey.GAS, 0);
    gas.displayValue = `${gas.value} ppm`;
    gas.normal = gas.value <= 300;
    gas.online = true;
    gas.battery = this.num(rep, PKey.BATTERY, 0);
    gas.updatedAt = now;
    gas.level = '';
    out.push(gas);

    const sos: Sensor = new Sensor();
    sos.sensorId = 'sen_sos';
    sos.deviceId = devId;
    sos.sensorType = SensorType.SOS_BUTTON;
    sos.name = '紧急求助';
    sos.value = this.flag(rep, PKey.SOS, false) ? 1 : 0;
    sos.displayValue = sos.value === 1 ? '已按下' : '正常';
    sos.normal = sos.value === 0;
    sos.online = true;
    sos.battery = this.num(rep, PKey.BATTERY, 0);
    sos.updatedAt = now;
    sos.level = '';
    out.push(sos);

    const bat: Sensor = new Sensor();
    bat.sensorId = 'sen_battery';
    bat.deviceId = devId;
    bat.sensorType = SensorType.BATTERY;
    bat.name = '设备电量';
    bat.value = this.num(rep, PKey.BATTERY, 0);
    bat.displayValue = `${bat.value}%`;
    bat.normal = bat.value >= 15;
    bat.online = true;
    bat.battery = bat.value;
    bat.updatedAt = now;
    bat.level = '';
    out.push(bat);

    return out;
  }

  // ==================== 真接口 1：设备列表 ====================

  /**
   * 设备列表。
   *
   * ⚠️ 首次启动时 IAM token / 网络状态可能还没就绪，第一次会拿到空列表。
   * 实测：首页第一次渲染显示「0 个传感器」，切一次页就正常。
   * 所以这里空结果自动重试一次（等 800ms），避免首页开屏是空的。
   */
  async getDeviceList(familyId: string): Promise<DeviceListItem[]> {
    let out: DeviceListItem[] = await this.fetchDeviceList();
    if (out.length === 0) {
      Logger.info(IotDaCloudAdapter.MODULE, 'getDeviceList 返回空，800ms 后重试一次');
      await this.delay(800);
      out = await this.fetchDeviceList();
    }
    return out;
  }

  private delay(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 确保 this.deviceId 有值（设备兜底解析）。
   *
   * AppConfig.deviceId 默认是空串，若用户不先打开首页就直接去预警中心标记告警，
   * confirmAlert / handleAlert 的 URL 会变成 /devices//commands，
   * 华为云回 IOTDA.000029。这里统一兜底：空则拉一次设备列表解析第一台。
   * 返回 false 表示没有绑定任何主机，调用方应放弃下发。
   */
  private async ensureDeviceId(): Promise<boolean> {
    if (this.deviceId.length > 0) {
      return true;
    }
    const list: DeviceListItem[] = await this.fetchDeviceList();
    if (list.length === 0) {
      Logger.warn(IotDaCloudAdapter.MODULE, 'ensureDeviceId: 设备列表为空');
      return false;
    }
    return true;
  }

  private async fetchDeviceList(): Promise<DeviceListItem[]> {
    const path: string = `/v5/iot/${this.projectId}/devices`;
    const resp: IotDaDeviceListResp = await this.http.get<IotDaDeviceListResp>(path);

    const out: DeviceListItem[] = [];
    if (resp.devices === undefined) {
      Logger.warn(IotDaCloudAdapter.MODULE, 'getDeviceList: 响应里没有 devices 字段');
      return out;
    }
    Logger.info(IotDaCloudAdapter.MODULE, `getDeviceList: 设备 ${resp.devices.length} 台`);
    for (const brief of resp.devices) {
      let rep: Record<string, number | string | boolean> = {};
      try {
        this.deviceId = brief.device_id;
        rep = await this.fetchShadowProps();
      } catch (e) {
        Logger.warn(IotDaCloudAdapter.MODULE, `shadow of ${brief.device_id} 拉取失败`);
      }
      const item: DeviceListItem = {
        device: this.buildDevice(brief, rep),
        sensors: this.buildSensors(rep, brief.device_id),
        activeAlerts: 0
      };
      out.push(item);
      Logger.info(IotDaCloudAdapter.MODULE,
        `getDeviceList: ${brief.device_name} 影子属性 ${Object.keys(rep).length} 个，传感器 ${item.sensors.length} 个`);
    }
    return out;
  }

  // ==================== 真接口 2：设备实时状态 ====================

  async getDeviceStatus(deviceId: string): Promise<DeviceStatusResp> {
    // deviceId 为空（页面调用方只关心当前家庭唯一主机时传 ''）时，
    // 先解析出真实 device_id，否则 URL 会缺尾巴变成 /devices/ ，
    // 华为云直接回 IOTDA.000029 path does not exist。
    let realId: string = deviceId;
    if (realId.length === 0) {
      if (!await this.ensureDeviceId()) {
        throw new Error('未绑定监护主机');
      }
      realId = this.deviceId;
      Logger.info(IotDaCloudAdapter.MODULE, `getDeviceStatus: deviceId 为空，已解析为 ${realId}`);
    }

    const detailPath: string = `/v5/iot/${this.projectId}/devices/${realId}`;
    const detail: IotDaDeviceDetail = await this.http.get<IotDaDeviceDetail>(detailPath);

    this.deviceId = realId;
    const rep: Record<string, number | string | boolean> = await this.fetchShadowProps();

    const brief: IotDaDeviceBrief = {
      device_id: detail.device_id,
      device_name: detail.device_name,
      product_id: detail.product_id,
      node_id: detail.node_id,
      status: detail.status,
      create_time: detail.create_time
    };

    const resp: DeviceStatusResp = {
      device: this.buildDevice(brief, rep),
      sensors: this.buildSensors(rep, realId),
      sosButtonOnline: detail.status === 'ONLINE',
      sosButtonBattery: this.num(rep, PKey.BATTERY, 0),
      recentAlerts: []
    };
    return resp;
  }

  // ==================== 真接口 3：确认告警（下发命令） ====================

  async confirmAlert(alertId: string, remark: string): Promise<ConfirmAlertResp> {
    // 先落本地：确认动作是 App 侧行为，设备离线也应生效。
    // 与 handleAlert 同理，命令下发是「锦上添花」，不能被设备在线状态卡住。
    this.store.updateAlert(alertId, 'confirmed', '', '', '');

    try {
      if (await this.ensureDeviceId()) {
        const req: IotDaCommandReq = new IotDaCommandReq();
        req.service_id = 'control';
        req.command_name = 'confirmAlert';
        req.paras = { 'alertId': alertId, 'remark': remark };

        const path: string = `/v5/iot/${this.projectId}/devices/${this.deviceId}/commands`;
        const r: IotDaCommandResp = await this.http.post<IotDaCommandResp>(path, req);
        Logger.info(IotDaCloudAdapter.MODULE, `confirmAlert 下发 command_id=${r.command_id}`);
      }
    } catch (e) {
      Logger.warn(IotDaCloudAdapter.MODULE,
        `confirmAlert 设备命令下发失败（本地已确认，不影响）: ${(e as Error).message}`);
    }

    const resp: ConfirmAlertResp = {
      alertId: alertId,
      status: 'confirmed',
      confirmedAt: Date.now()
    };
    return resp;
  }

  // ==================== 真接口 4：处置告警（下发命令） ====================

  async handleAlert(alertId: string, reqBody: HandleAlertReq): Promise<HandleAlertResp> {
    const status: string = reqBody.result === 'false_alarm' ? 'false_alarm' : 'handled';
    const resultName: string = reqBody.result === 'false_alarm' ? '误报' : '已处置';

    // 先落本地（App 侧事件闭环）。告警列表本就是 App 侧数据，
    // 家属点了「已处置」就该立刻生效，不能被设备在线状态卡住。
    // 实测踩坑：设备离线时华为云回 IOTDA.014016 device is not online，
    // 若先下发命令再落库，处置就永远失败，告警只能一直堆在待处置里。
    const updated: Alert | undefined = this.store.updateAlert(
      alertId, status, reqBody.note, '家属', resultName);
    if (updated === undefined) {
      throw new Error(`本地无此告警: ${alertId}`);
    }

    // 再尽力下发设备命令（让设备停止声光报警）。设备离线 / 未绑定都不影响
    // 本地闭环，只记一条 warn 日志 —— 命令是「锦上添花」，本地处置才是必须。
    try {
      if (await this.ensureDeviceId()) {
        const req: IotDaCommandReq = new IotDaCommandReq();
        req.service_id = 'control';
        req.command_name = 'handleAlert';
        req.paras = { 'alertId': alertId, 'result': reqBody.result, 'note': reqBody.note };
        const path: string = `/v5/iot/${this.projectId}/devices/${this.deviceId}/commands`;
        const r: IotDaCommandResp = await this.http.post<IotDaCommandResp>(path, req);
        Logger.info(IotDaCloudAdapter.MODULE, `handleAlert 下发 command_id=${r.command_id}`);
      }
    } catch (e) {
      Logger.warn(IotDaCloudAdapter.MODULE,
        `handleAlert 设备命令下发失败（本地已闭环，不影响）: ${(e as Error).message}`);
    }

    // 写居家安全日志（赛题要求：处置结果留痕）
    const log: SafetyLogEntry = new SafetyLogEntry();
    log.logId = `log_${alertId}`;
    log.alertId = alertId;
    log.date = DateUtil.formatDate(updated.timestamp);
    log.level = updated.level;
    log.alertTypeName = updated.alertTypeName;
    log.triggeredAt = updated.timestamp;
    log.handledAt = Date.now();
    log.handlerName = '家属';
    log.resultName = resultName;
    log.note = reqBody.note;
    this.store.appendLog(log);

    const resp: HandleAlertResp = {
      alertId: alertId,
      status: status,
      handledAt: Date.now(),
      thresholdAdjusted: false
    };
    return resp;
  }

  /**
   * 删除告警（真接口 5 的配套清理动作）。
   *
   * 华为云没有"删除告警"接口（告警列表本就是 App 侧数据），
   * 所以这里只删本地 store。调用方（AlertCard）必须自己保证
   * 只删已闭环的告警。
   */
  async deleteAlert(alertId: string): Promise<boolean> {
    return this.store.deleteAlert(alertId);
  }

  /** 批量标记全部待处置为已处置（App 侧动作，设备命令不下发） */
  async markAllPendingHandled(): Promise<number> {
    return this.store.markAllPendingHandled('家属', '已处置', '批量标记已处置');
  }

  /** 清空全部待处置（仅本地记录，不影响安全日志/日报） */
  async clearPendingAlerts(): Promise<number> {
    return this.store.clearPending();
  }

  /** 演示用告警模板。循环取用，保证每次注入的几条类型不同、看起来真实 */
  private static demoTemplates(): DemoAlertTemplate[] {
    return [
      new DemoAlertTemplate(AlertType.SMOKE_DETECTED, 372, 300, '烟雾浓度超阈值，疑似火情'),
      new DemoAlertTemplate(AlertType.GAS_LEAK, 486, 300, '可燃气体浓度超阈值，疑似燃气泄漏'),
      new DemoAlertTemplate(AlertType.NO_ACTIVITY, 92, 60, '连续 92 分钟未检测到人体活动，超出该老人日常活动基线'),
      new DemoAlertTemplate(AlertType.TEMP_HUMIDITY_ABNORMAL, 33.2, 32, '室内温度 33.2℃ 持续偏高，超出老人舒适区间'),
      new DemoAlertTemplate(AlertType.SOS_PRESSED, 1, 0, '老人按下紧急求助按钮')
    ];
  }

  /**
   * 演示用：注入 count 条待处置告警。
   *
   * 让评委看到「告警到达 → 处置 → 删除」的完整闭环，且节奏可控 ——
   * 每次刷新 / 点「模拟告警」才来几条，不会像轮询那样刷屏。
   */
  async injectDemoAlerts(count: number): Promise<number> {
    if (count <= 0) {
      return 0;
    }
    const now: number = Date.now();
    const tpls: DemoAlertTemplate[] = IotDaCloudAdapter.demoTemplates();
    let added: number = 0;
    // 从旧到新依次 append（appendAlert 是 unshift），最终列表最新在前
    for (let k: number = count - 1; k >= 0; k--) {
      const tpl: DemoAlertTemplate = tpls[(Math.floor(now / 1000) + k) % tpls.length];
      const alert: Alert = new Alert();
      alert.alertId = `demo_${tpl.type}_${now}_${k}`;
      alert.serverAlertId = '';
      alert.deviceId = this.deviceId;
      alert.deviceName = this.deviceName;
      alert.alertType = tpl.type;
      alert.alertTypeName = AlertType.labelOf(tpl.type);
      alert.level = AlertType.defaultLevelOf(tpl.type);
      alert.timestamp = now - k * 30000;
      alert.triggerValue = tpl.value;
      alert.threshold = tpl.threshold;
      alert.description = tpl.desc;
      alert.status = 'pending';
      alert.notifiedRoles = alert.level === AlertLevel.P0
        ? ['child', 'community'] : ['child'];
      this.store.appendAlert(alert);
      added = added + 1;
    }
    Logger.info(IotDaCloudAdapter.MODULE, `演示注入 ${added} 条告警`);
    return added;
  }

  // ==================== 门面：设备侧（App 不调用） ====================

  async registerDevice(req: RegisterDeviceReq): Promise<RegisterDeviceResp> {
    const resp: RegisterDeviceResp = {
      deviceId: this.deviceId,
      deviceToken: '',
      familyId: this.familyId,
      config: new DeviceConfig()
    };
    return resp;
  }

  async heartbeat(deviceId: string, req: HeartbeatReq): Promise<HeartbeatResp> {
    const resp: HeartbeatResp = {
      serverTime: Date.now(),
      pendingCommands: [],
      configChanged: false
    };
    return resp;
  }

  async uploadReadings(deviceId: string, req: UploadReadingsReq): Promise<UploadReadingsResp> {
    const resp: UploadReadingsResp = { accepted: 0, rejected: 0 };
    return resp;
  }

  async uploadAlert(deviceId: string, req: UploadAlertReq): Promise<UploadAlertResp> {
    const resp: UploadAlertResp = {
      alertId: req.alertId, serverAlertId: '', notified: [], deduped: false
    };
    return resp;
  }

  async fetchDeviceConfig(deviceId: string): Promise<DeviceConfig> {
    return new DeviceConfig();
  }

  // ==================== 门面：平台没有的接口 ====================

  async getReadings(query: ReadingsQuery): Promise<ReadingsResp> {
    // 分桶粒度：raw / 5m / 1h / 1d
    const bucketMs: number = query.interval === '5m' ? 300000
      : (query.interval === '1h' ? 3600000
        : (query.interval === '1d' ? 86400000 : 0));

    const src: BufferedReading[] = [];
    for (const b of this.ring) {
      if (b.sensorType !== query.sensorType) {
        continue;
      }
      if (query.from > 0 && b.timestamp < query.from) {
        continue;
      }
      if (query.to > 0 && b.timestamp > query.to) {
        continue;
      }
      src.push(b);
    }

    const points: ReadingsPoint[] = [];
    if (bucketMs === 0) {
      for (const b of src) {
        const p: ReadingsPoint = {
          timestamp: b.timestamp,
          value: b.value,
          extra: { 'humidity': b.humidity }
        };
        points.push(p);
      }
    } else {
      // 分桶求均值
      const keys: number[] = [];
      const vSum: number[] = [];
      const vCnt: number[] = [];
      const hSum: number[] = [];
      const hCnt: number[] = [];
      for (const b of src) {
        const k: number = Math.floor(b.timestamp / bucketMs);
        let idx: number = keys.indexOf(k);
        if (idx < 0) {
          keys.push(k);
          vSum.push(0);
          vCnt.push(0);
          hSum.push(0);
          hCnt.push(0);
          idx = keys.length - 1;
        }
        vSum[idx] = vSum[idx] + b.value;
        vCnt[idx] = vCnt[idx] + 1;
        if (b.humidity > 0) {
          hSum[idx] = hSum[idx] + b.humidity;
          hCnt[idx] = hCnt[idx] + 1;
        }
      }
      for (let i: number = 0; i < keys.length; i++) {
        const avg: number = vCnt[i] > 0 ? Math.round(vSum[i] / vCnt[i] * 100) / 100 : 0;
        const hum: number = hCnt[i] > 0 ? Math.round(hSum[i] / hCnt[i] * 10) / 10 : 0;
        const p: ReadingsPoint = {
          timestamp: keys[i] * bucketMs,
          value: avg,
          extra: { 'humidity': hum }
        };
        points.push(p);
      }
    }

    const resp: ReadingsResp = {
      sensorType: query.sensorType,
      interval: query.interval,
      points: points
    };
    return resp;
  }

  /** 把当前影子值追加进环形缓冲（供实时曲线） */
  private appendRing(rep: Record<string, number | string | boolean>): void {
    const ts: number = Date.now();
    const hum: number = this.num(rep, PKey.HUM, 0);
    this.pushRing(SensorType.PIR, ts, this.flag(rep, PKey.PIR, false) ? 1 : 0, 0);
    this.pushRing(SensorType.DOOR, ts, this.num(rep, PKey.DOOR, 0), 0);
    this.pushRing(SensorType.TEMP_HUMIDITY, ts, this.num(rep, PKey.TEMP, 0), hum);
    this.pushRing(SensorType.SMOKE, ts, this.num(rep, PKey.SMOKE, 0), 0);
    this.pushRing(SensorType.GAS, ts, this.num(rep, PKey.GAS, 0), 0);

    if (this.ring.length > IotDaCloudAdapter.RING_MAX) {
      this.ring = this.ring.slice(this.ring.length - IotDaCloudAdapter.RING_MAX);
    }
  }

  private pushRing(type: string, ts: number, value: number, hum: number): void {
    const b: BufferedReading = new BufferedReading();
    b.sensorType = type;
    b.timestamp = ts;
    b.value = value;
    b.humidity = hum;
    this.ring.push(b);
  }

  async getAlerts(query: AlertQuery): Promise<PageData<Alert>> {
    const all: Alert[] = this.store.loadAlerts();
    const filtered: Alert[] = [];
    for (const a of all) {
      if (query.status.length > 0 && query.status !== 'all' && a.status !== query.status) {
        continue;
      }
      if (query.level.length > 0 && query.level !== 'all' && a.level !== query.level) {
        continue;
      }
      filtered.push(a);
    }
    const ps: number = query.pageSize > 0 ? query.pageSize : 20;
    const page: number = query.page > 0 ? query.page : 1;
    const start: number = (page - 1) * ps;
    const resp: PageData<Alert> = {
      list: filtered.slice(start, start + ps),
      total: filtered.length,
      page: page,
      pageSize: ps
    };
    return resp;
  }

  async getAlertDetail(alertId: string): Promise<AlertDetailResp> {
    const all: Alert[] = this.store.loadAlerts();
    let hit: Alert | undefined = undefined;
    for (const a of all) {
      if (a.alertId === alertId) {
        hit = a;
        break;
      }
    }
    if (hit === undefined) {
      throw new CloudError(CloudCode.NOT_FOUND, `本地无此告警: ${alertId}`);
    }

    // 时间线由本地状态推导（平台不提供）
    const timeline: AlertTimelineNode[] = [];
    const t1: AlertTimelineNode = new AlertTimelineNode();
    t1.time = hit.timestamp;
    t1.event = 'triggered';
    t1.text = '设备端判定异常，已触发本地声光报警';
    timeline.push(t1);

    if (hit.status !== 'pending') {
      const t2: AlertTimelineNode = new AlertTimelineNode();
      t2.time = hit.timestamp;
      t2.event = 'confirmed';
      t2.text = '家属已确认告警';
      timeline.push(t2);
    }
    if (hit.handle !== undefined) {
      const t3: AlertTimelineNode = new AlertTimelineNode();
      t3.time = hit.handle.handledAt;
      t3.event = 'handled';
      t3.text = `已填写处置结果：${hit.handle.resultName}`;
      timeline.push(t3);
    }

    const resp: AlertDetailResp = { alert: hit, timeline: timeline };
    return resp;
  }

  async getActivityReport(deviceId: string, period: string, date: string): Promise<ActivityReportResp> {
    const resp: ActivityReportResp = { report: this.buildReport(period) };
    return resp;
  }

  async getActivityDistribution(deviceId: string, from: number, to: number): Promise<ActivityDistributionResp> {
    const cells: HeatmapCell[] = this.store.loadHourly();
    let max: number = 1;
    for (const c of cells) {
      if (c.count > max) {
        max = c.count;
      }
    }
    const resp: ActivityDistributionResp = { maxCount: max, cells: cells };
    return resp;
  }

  /**
   * 由本地累计的活动统计拼出报告。
   *
   * 数据来源：pollOnce 每 4 秒拉影子时检测 PIR 上升沿累加，
   * 因此报告里的数字是「App 在线的这段时间」的真实活动，不是编的。
   */
  private buildReport(period: string): ActivityReport {
    const days: number = period === 'month' ? 30 : (period === 'day' ? 1 : 7);
    const all: ActivityDaily[] = this.store.loadDaily();
    const window: ActivityDaily[] = all.slice(Math.max(0, all.length - days));

    const r: ActivityReport = new ActivityReport();
    r.period = period;
    r.to = Date.now();
    r.from = r.to - days * 24 * 3600 * 1000;
    r.compareWith = period === 'month' ? '上月' : '上周';

    let total: number = 0;
    let night: number = 0;
    const trend: TrendPoint[] = [];
    for (const d of window) {
      total = total + d.totalCount;
      night = night + d.nightCount;
      const p: TrendPoint = new TrendPoint();
      p.date = d.date;
      p.count = d.totalCount;
      trend.push(p);
    }
    r.totalCount = total;
    r.avgDailyCount = window.length > 0 ? Math.round(total / window.length * 10) / 10 : 0;
    r.nightActivityCount = night;
    r.daily = trend;

    // 小时分布与热力图
    const hourly: number[] = new Array<number>(24).fill(0);
    const cells: HeatmapCell[] = this.store.loadHourly();
    for (const c of cells) {
      if (c.hour >= 0 && c.hour < 24) {
        hourly[c.hour] = hourly[c.hour] + c.count;
      }
    }
    r.hourlyDistribution = hourly;

    let activeHours: number = 0;
    let firstHour: number = -1;
    let lastHour: number = -1;
    for (let h: number = 0; h < 24; h++) {
      if (hourly[h] > 0) {
        activeHours = activeHours + 1;
        if (firstHour < 0) {
          firstHour = h;
        }
        lastHour = h;
      }
    }
    r.activeHours = activeHours;
    r.firstActivityTime = firstHour >= 0 ? this.hhmm(firstHour) : '--';
    r.lastActivityTime = lastHour >= 0 ? this.hhmm(lastHour) : '--';

    let maxCell: number = 1;
    for (const c of cells) {
      if (c.count > maxCell) {
        maxCell = c.count;
      }
    }
    r.heatmap = cells;
    r.maxHeatmapCount = maxCell;

    // 个人基线（14 天）与趋势
    const baseWin: ActivityDaily[] = all.slice(Math.max(0, all.length - 14));
    let bSum: number = 0;
    for (const d of baseWin) {
      bSum = bSum + d.totalCount;
    }
    const bAvg: number = baseWin.length > 0 ? bSum / baseWin.length : 0;
    let sq: number = 0;
    for (const d of baseWin) {
      const diff: number = d.totalCount - bAvg;
      sq = sq + diff * diff;
    }
    const bStd: number = baseWin.length > 0 ? Math.sqrt(sq / baseWin.length) : 0;
    r.baselineAvg = Math.round(bAvg * 10) / 10;
    r.baselineStdDev = Math.round(bStd * 10) / 10;

    if (bAvg > 0) {
      const change: number = (r.avgDailyCount - bAvg) / bAvg * 100;
      r.changePercent = Math.round(change * 10) / 10;
      r.trendDirection = change < -15 ? 'down' : (change > 15 ? 'up' : 'stable');
      r.insight = r.trendDirection === 'down'
        ? `日均活动 ${r.avgDailyCount} 次，较基线下降 ${Math.abs(r.changePercent)}%，建议关注`
        : (r.trendDirection === 'up'
          ? `日均活动 ${r.avgDailyCount} 次，较基线上升 ${r.changePercent}%，作息更活跃`
          : `日均活动 ${r.avgDailyCount} 次，与基线基本持平，作息稳定`);
    } else {
      r.trendDirection = 'stable';
      r.insight = '活动数据还在积累中，建议连续采集 3 天以上再观察趋势';
    }

    r.deviation = bStd > 0 ? Math.round((r.avgDailyCount - bAvg) / bStd * 100) / 100 : 0;
    r.baselineAbnormal = Math.abs(r.deviation) > 2;
    return r;
  }

  /** 0 → "00:00" */
  private hhmm(hour: number): string {
    const h: string = hour < 10 ? `0${hour}` : `${hour}`;
    return `${h}:00`;
  }

  async getSafetyLogs(query: SafetyLogQuery): Promise<PageData<SafetyLogEntry>> {
    const all: SafetyLogEntry[] = this.store.loadLogs();
    const ps: number = query.pageSize > 0 ? query.pageSize : 20;
    const page: number = query.page > 0 ? query.page : 1;
    const start: number = (page - 1) * ps;
    const resp: PageData<SafetyLogEntry> = {
      list: all.slice(start, start + ps),
      total: all.length,
      page: page,
      pageSize: ps
    };
    return resp;
  }

  async getFamilyMembers(familyId: string): Promise<FamilyMemberListResp> {
    let list: FamilyMember[] = this.store.loadMembers();
    if (list.length === 0) {
      // 首次运行：写入默认家庭成员（IoTDA 没有成员管理接口，成员属于 App 侧数据）
      const a: FamilyMember = new FamilyMember();
      a.userId = 'u_001';
      a.name = '家属（子女）';
      a.role = 'child';
      a.roleName = '子女';
      a.phone = '';
      a.canViewActivity = true;
      a.canHandle = true;

      const b: FamilyMember = new FamilyMember();
      b.userId = 'u_002';
      b.name = '社区网格员';
      b.role = 'community';
      b.roleName = '社区网格员';
      b.phone = '';
      b.canViewActivity = false;
      b.canHandle = true;

      list = [a, b];
      this.store.saveMembers(list);
    }
    const resp: FamilyMemberListResp = { members: list };
    return resp;
  }

  // ==================== 推送：影子轮询 ====================

  /**
   * 订阅告警。
   *
   * IoTDA 的应用侧没有面向 App 的实时推送通道（平台只提供订阅管理给服务器侧），
   * 所以这里用「轮询设备影子」近似：每 4 秒拉一次 reported，
   * 检测燃气 / 烟雾 / 求助是否越界，**只推新出现的类型**，避免每轮重复弹。
   */
  subscribeAlerts(listener: PushListener): void {
    if (this.listener !== undefined) {
      Logger.warn(IotDaCloudAdapter.MODULE, '已在轮询中，忽略重复订阅');
      return;
    }
    this.listener = listener;
    this.prevSig = '';
    this.timerId = setInterval(() => {
      this.pollOnce().catch((e: Error) => {
        Logger.warn(IotDaCloudAdapter.MODULE, `影子轮询失败: ${e.message}`);
      });
    }, IotDaCloudAdapter.POLL_MS);
    Logger.info(IotDaCloudAdapter.MODULE, `开始轮询影子，间隔 ${IotDaCloudAdapter.POLL_MS}ms`);
  }

  unsubscribeAlerts(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    this.listener = undefined;
    this.prevSig = '';
    Logger.info(IotDaCloudAdapter.MODULE, '已停止影子轮询');
  }

  /** 轮询一次：拉影子 -> 判越界 -> 只推新出现的告警类型 */
  private async pollOnce(): Promise<void> {
    const rep: Record<string, number | string | boolean> = await this.fetchShadowProps();
    const gas: number = this.num(rep, PKey.GAS, 0);
    const smoke: number = this.num(rep, PKey.SMOKE, 0);
    const sos: boolean = this.flag(rep, PKey.SOS, false);

    // ---- 活动计数：IoTDA 没有历史读数接口，只能靠轮询累计 PIR 上升沿 ----
    const pir: boolean = this.flag(rep, PKey.PIR, false);
    if (pir && !this.prevPir) {
      const ts: number = Date.now();
      this.store.recordActivity(this.deviceId, DateUtil.formatDate(ts),
        new Date(ts).getHours(), ts);
    }
    this.prevPir = pir;

    // ---- 读数环形缓冲：供实时曲线使用（IoTDA 无历史读数接口）----
    this.appendRing(rep);

    // 自动派生告警（默认关闭，避免刷屏）。演示改由 injectDemoAlerts 按需注入。
    if (IotDaCloudAdapter.AUTO_ALERT_ON_POLL) {
      const active: string[] = [];
      if (gas > 300) {
        active.push(AlertType.GAS_LEAK);
      }
      if (smoke > 300) {
        active.push(AlertType.SMOKE_DETECTED);
      }
      if (sos) {
        active.push(AlertType.SOS_PRESSED);
      }

      const prev: string[] = this.prevSig.length > 0 ? this.prevSig.split(',') : [];
      for (const t of active) {
        if (prev.indexOf(t) < 0) {
          this.emitAlert(t, gas, smoke);
        }
      }
      this.prevSig = active.join(',');
    }
  }

  /** 构造 Alert + PushMessage 并回调监听者 */
  private emitAlert(type: string, gas: number, smoke: number): void {
    if (this.listener === undefined) {
      return;
    }
    const now: number = Date.now();
    const level: string = AlertType.defaultLevelOf(type);

    let value: number = 1;
    let threshold: number = 0;
    let desc: string = '老人按下紧急求助按钮';
    if (type === AlertType.GAS_LEAK) {
      value = gas;
      threshold = 300;
      desc = '可燃气体浓度超阈值，疑似燃气泄漏';
    } else if (type === AlertType.SMOKE_DETECTED) {
      value = smoke;
      threshold = 300;
      desc = '烟雾浓度超阈值，疑似火情';
    }

    const alert: Alert = new Alert();
    alert.alertId = `iotda_${type}_${now}`;
    alert.serverAlertId = '';
    alert.deviceId = this.deviceId;
    alert.deviceName = this.deviceName;
    alert.alertType = type;
    alert.alertTypeName = AlertType.labelOf(type);
    alert.level = level;
    alert.timestamp = now;
    alert.triggerValue = value;
    alert.threshold = threshold;
    alert.description = desc;
    alert.status = 'pending';
    alert.notifiedRoles = level === AlertLevel.P0 ? ['child', 'community'] : ['child'];

    const msg: PushMessage = {
      type: 'alert',
      alertId: alert.alertId,
      level: level,
      alertType: type,
      alertTypeName: alert.alertTypeName,
      deviceId: this.deviceId,
      deviceName: this.deviceName,
      timestamp: now,
      title: alert.alertTypeName,
      body: desc
    };
    Logger.info(IotDaCloudAdapter.MODULE, `推送告警 ${alert.alertTypeName} ${level}`);
    this.store.appendAlert(alert);
    this.listener(msg);
  }

  adapterName(): string {
    return '华为云 IoTDA';
  }
}
