/**
 * @file    IotDaConfig.ets
 * @brief   华为云 IoTDA 接入配置（集中管理，改这里就行）
 *
 * 凭据不在本文件里：账号名 / 子用户名 / 密码 放在同目录的 IotDaSecret.ets，
 * 该文件已被 .gitignore 排除，不会进仓库。
 * 新环境首次拉代码后，复制 IotDaSecret.example.ets 为 IotDaSecret.ets 并填值。
 *
 * 为什么用「子用户」而不是主账号：
 *    主账号属于华为账号体系，密码不走 IAM 的密码认证，
 *    调 /v3/auth/tokens 会一直 401。子用户是纯 IAM 用户，密码认证可用。
 */

import { IotDaSecret } from './IotDaSecret';

export class IotDaConfig {
  /** 总开关：false 时回落到 MockCloudAdapter */
  static readonly ENABLED: boolean = true;

  /** 应用侧接入域名（控制台「总览 → 接入信息 → 应用接入 → HTTPS」）*/
  static readonly ENDPOINT: string = 'https://2eb62113b2.st1.iotda-app.cn-north-4.myhuaweicloud.com';

  /** 区域，用于 IAM 地址拼接 */
  static readonly REGION: string = 'cn-north-4';

  /** 项目 ID（「我的凭证 → 项目」）*/
  static readonly PROJECT_ID: string = '01a157285f937fd9b822aba3bd9ddd6f';

  /**
   * 设备 ID —— 注意格式是 {产品ID}_{设备标识码}
   * 不是另一个 24 位十六进制，MQTT 和 REST 通用这一个
   */
  static readonly DEVICE_ID: string = '6ad6dbb77f2e6c302fa4ef57_sy-rk2206-001';

  /** 设备显示名（演示数据的告警文案用；真实名字以影子查询结果为准） */
  static readonly DEVICE_NAME: string = '王奶奶家网关';

  /** 家庭 ID，本地业务用，平台侧无对应概念 */
  static readonly FAMILY_ID: string = 'fam_0001';

  // ==================== 演示数据（截图 / 答辩用） ====================

  /**
   * 演示模式总开关。
   *
   * 为什么需要：真实板子只在有事件时上报，且刚装机时 App 本地没有任何
   * 活动统计与告警历史，活动报告 / 热力图 / 预警中心全是空的，
   * 截图和答辩演示都没法看。
   *
   * 打开后做三件事（都不覆盖真实数据，只补缺口）：
   *   1. 首次启动种入 60 天活动统计 + 30 天小时分布 + 9 条历史告警
   *   2. 实时曲线的历史缺口按当前真实读数为锚点补形
   *   3. 设备离线时按在线展示、体征为空时填演示值
   *
   * ⚠️ 正式运行 / 交付时置 false：关掉后页面只显示真实数据。
   */
  static readonly DEMO_MODE: boolean = true;

  /**
   * 实时曲线历史补形。
   *
   * getReadings 只从内存环形缓冲取数，App 刚启动时只有几个点，
   * 曲线是一根断线。打开后用「当前真实值 + 昼夜节律」合成历史段，
   * 环形缓冲里已有的点一律用真实值，不覆盖。
   */
  static readonly DEMO_SYNTH_READINGS: boolean = true;

  // ---------- IAM 子用户凭据（真实值在本地未跟踪的 IotDaSecret.ets）----------

  /** 华为云账号名（「我的凭证」第一屏，注意末尾是 - 不是 _）*/
  static readonly DOMAIN_NAME: string = IotDaSecret.DOMAIN_NAME;

  /** IAM 子用户名 */
  static readonly USER_NAME: string = IotDaSecret.USER_NAME;

  /** 子用户密码 */
  static readonly PASSWORD: string = IotDaSecret.PASSWORD;
}
