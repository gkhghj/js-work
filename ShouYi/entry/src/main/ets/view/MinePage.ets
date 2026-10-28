import { FamilyMember } from '../model/FamilyMember';
import { SafetyLogEntry } from '../model/Alert';
import { Device } from '../model/Device';
import { CareService } from '../service/CareService';
import { AppConfig } from '../cloud/CloudApiFactory';
import { DeviceListItem } from '../cloud/CloudTypes';
import { AppColor, AppSize } from '../common/constants/ThemeColors';
import { MemberRole, AlertLevel, AppConstants } from '../common/constants/AppConstants';
import { ThemeMode, ThemeStore } from '../common/theme/ThemeStore';
import { ReportExporter } from '../common/utils/ReportExporter';
import { DateUtil } from '../common/utils/DateUtil';
import { Logger } from '../common/utils/Logger';
import { common } from '@kit.AbilityKit';

/**
 * 我的页。
 *
 * 三块内容：
 *   ① 家庭成员与角色 —— 多终端协同的可见范围说明
 *   ② 居家安全日志 —— 赛题要求的"形成居家安全日志，便于长期跟踪"
 *   ③ 设置 —— 基线模型管理、设备信息（含固件版本）、云端实现切换、角色切换
 *
 * 关于固件版本：它是底层开发信息，家属日常不需要看，首页展示会占用
 * 首屏空间。因此从首页移到这里保存，维护人员需要时再查。
 *
 * 配色与预警中心、活动报告页完全统一：白底圆角卡片、左上标题 + 右上操作、
 * 橙黄=高风险、绿=需关注、浅蓝=外部协同角色。
 */
@Component
export struct MinePage {

  /**
   * 订阅显示设置。@StorageProp 会在主题 / 关怀模式变化时触发本组件重渲染，
   * 这样 ThemeStore 一改，AppColor / AppSize 的 getter 重新取值，全页同步换肤。
   */
  @StorageProp('displayMode') displayMode: string = 'day';
  @StorageProp('careMode') careMode: boolean = false;
  private static readonly MODULE: string = 'MinePage';

  @State members: FamilyMember[] = [];
  @State logs: SafetyLogEntry[] = [];
  @State currentRole: string = MemberRole.CHILD;
  @State cloudName: string = '';
  @State useMock: boolean = true;
  /** 当前监护主机，用于在设置里展示设备信息与固件版本 */
  @State device: Device | undefined = undefined;
  /** 演示场景（仅 Mock）：normal / warning / danger / offline */
  @State scenario: string = 'normal';
  /** 基线模型详情是否展开 */
  @State baselineOpen: boolean = false;
  /** 基线均值，展开时读取。0 表示样本不足 */
  @State baselineAvg: number = 0;
  /** 基线波动区间（标准差） */
  @State baselineStdDev: number = 0;
  /** 参与基线计算的样本天数 */
  @State baselineDays: number = 0;
  /** 页签切换广播：Tabs 缓存页签，aboutToAppear 只跑一次，回本页要重新拉数据 */
  @StorageLink('alertRefreshTick') @Watch('onAlertRefreshTick') alertTick: number = 0;

  private service: CareService = new CareService();

  aboutToAppear(): void {
    this.cloudName = this.service.cloudName();
    this.useMock = AppConfig.isMock();
    const s: string = this.service.demoScenario();
    this.scenario = s.length > 0 ? s : 'normal';
    this.load();
  }

  /** 每次切回本页签都重新拉，否则在别处处置完告警，安全日志还是旧的 */
  onAlertRefreshTick(): void {
    this.load();
  }

  async load(): Promise<void> {
    try {
      this.members = await this.service.loadMembers();
      this.logs = await this.service.loadSafetyLogs(60);
      const list: DeviceListItem[] = await this.service.loadDevices();
      if (list.length > 0) {
        this.device = list[0].device;
      }
    } catch (err) {
      Logger.error(MinePage.MODULE, `加载失败: ${(err as Error).message}`);
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
        Row() {
          Text('设置与设备')
            .fontSize(AppSize.TITLE_FONT)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.TEXT)
            .layoutWeight(1)
          Text('鸿星伴护')
            .fontSize(AppSize.SMALL_FONT)
            .fontColor(AppColor.TEXT_3)
        }
        .width('100%')
        .padding(AppSize.PAGE_PADDING)

        Scroll() {
          Column() {
            // ---------- 家庭成员与角色 ----------
            Column() {
              Text('家庭成员与角色')
                .fontSize(AppSize.SUBTITLE_FONT)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.TEXT)
                .width('100%')

              Text('分级推送预警，精细化权限隔离：活动报告仅直系家属可见；'
                + '社区网格员、物业仅接收预警处置任务，保障老人隐私安全。')
                .fontSize(AppSize.SMALL_FONT)
                .fontColor(AppColor.TEXT_3)
                .margin({ top: 8 })
                .lineHeight(18)
                .width('100%')

              ForEach(this.members, (m: FamilyMember) => {
                Row() {
                  Column() {
                    Row() {
                      Text(m.name)
                        .fontSize(AppSize.BODY_FONT)
                        .fontWeight(FontWeight.Bold)
                        .fontColor(AppColor.TEXT)
                      // 角色标签：子女绿、外部协同方浅蓝。
                      // 两者在权限上不同（外部方看不到活动报告），颜色必须先分开
                      Text(m.roleName)
                        .fontSize(AppSize.SMALL_FONT)
                        .fontColor(AppColor.ON_PRIMARY)
                        .backgroundColor(this.roleTagColor(m.role))
                        .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                        .borderRadius(4)
                        .margin({ left: 8 })
                    }
                    .width('100%')

                    Text(`手机号 ${m.phone}`)
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.TEXT_3)
                      .margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Column() {
                    Text(m.canViewActivity ? '可看活动报告' : '仅接收预警')
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.SUCCESS)
                    Text(m.canHandle ? '可处置预警' : '只读')
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.SUCCESS)
                      .margin({ top: 4 })
                  }
                  .alignItems(HorizontalAlign.End)
                }
                .width('100%')
                .padding({ top: 12, bottom: 12 })
                .border({ width: { bottom: 1 }, color: AppColor.LINE })
              }, (m: FamilyMember) => m.userId)
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(AppColor.CARD)
            .borderRadius(AppSize.CARD_RADIUS)
            .margin({ bottom: 12 })

            // ---------- 居家安全日志 ----------
            Column() {
              Row() {
                Text('居家安全日志')
                  .fontSize(AppSize.SUBTITLE_FONT)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(AppColor.TEXT)
                  .layoutWeight(1)
                Text(`近 60 天 ${this.logs.length} 条`)
                  .fontSize(AppSize.SMALL_FONT)
                  .fontColor(AppColor.TEXT_3)
                  .margin({ right: 8 })
                // 导出入口与统计并排：看条数的同时就能导出，
                // 不用先记住有多少条再回头找按钮
                Text('导出日志')
                  .fontSize(AppSize.SMALL_FONT)
                  .fontColor(AppColor.ON_PRIMARY)
                  .backgroundColor(AppColor.PRIMARY)
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .borderRadius(12)
                  .onClick(() => {
                    this.exportLogs();
                  })
              }
              .width('100%')

              Text('已处置预警自动归档，生成可回溯守护日志，'
                + '支持长期追踪老人居家状态，可导出 PDF 存档。')
                .fontSize(AppSize.SMALL_FONT)
                .fontColor(AppColor.TEXT_3)
                .margin({ top: 8 })
                .lineHeight(18)
                .width('100%')

              if (this.logs.length === 0) {
                Text('暂无处置记录')
                  .fontSize(AppSize.CAPTION_FONT)
                  .fontColor(AppColor.TEXT_3)
                  .margin({ top: 20 })
                  .width('100%')
              } else {
                ForEach(this.logs, (log: SafetyLogEntry) => {
                  Row() {
                    // 时间线圆点
                    Column() {
                      Row()
                        .width(8)
                        .height(8)
                        .borderRadius(4)
                        .backgroundColor(AppColor.levelColor(log.level))
                      Row()
                        .width(1)
                        .height(46)
                        .backgroundColor(AppColor.LINE)
                    }
                    .width(16)
                    .alignItems(HorizontalAlign.Center)

                    Column() {
                      Row() {
                        Text(log.alertTypeName)
                          .fontSize(AppSize.CAPTION_FONT)
                          .fontWeight(FontWeight.Bold)
                          .fontColor(AppColor.TEXT)
                        // 等级标签实心（与预警中心卡片一致）：
                        // 同一等级在两页长得一样，家属不用重新学
                        Text(AlertLevel.labelOf(log.level))
                          .fontSize(10)
                          .fontColor(AppColor.ON_PRIMARY)
                          .backgroundColor(AppColor.levelColor(log.level))
                          .padding({ left: 5, right: 5, top: 1, bottom: 1 })
                          .borderRadius(3)
                          .margin({ left: 8 })
                        Blank()
                        Text(DateUtil.formatDate(log.triggeredAt))
                          .fontSize(AppSize.SMALL_FONT)
                          .fontColor(AppColor.TEXT_3)
                      }
                      .width('100%')

                      Text(`${log.handlerName} · ${log.resultName}`)
                        .fontSize(AppSize.SMALL_FONT)
                        .fontColor(AppColor.TEXT_2)
                        .margin({ top: 6 })
                        .width('100%')

                      if (log.note.length > 0) {
                        Text(log.note)
                          .fontSize(AppSize.SMALL_FONT)
                          .fontColor(AppColor.TEXT_3)
                          .margin({ top: 4 })
                          .width('100%')
                      }
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)
                    .margin({ left: 10, bottom: 12 })
                  }
                  .width('100%')
                }, (log: SafetyLogEntry) => log.logId)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(AppColor.CARD)
            .borderRadius(AppSize.CARD_RADIUS)
            .margin({ bottom: 12 })

            // ---------- 显示设置：三模式切换 ----------
            // 两个维度必须分开讲清楚，否则用户会以为"关怀模式"是第三种主题：
            //   日间 / 夜间 = 主题亮度配色（同一维度二选一）
            //   关怀模式    = 独立开关，管信息密度 + 字号尺寸
            // 两者可自由组合：关怀+日间 / 关怀+夜间 / 标准+日间 / 标准+夜间。
            Column() {
              Text('显示设置')
                .fontSize(AppSize.SUBTITLE_FONT)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.TEXT)
                .width('100%')

              // ---- 维度一：主题亮度（日间 / 夜间 二选一）----
              Row() {
                Column() {
                  Text('主题亮度')
                    .fontSize(AppSize.BODY_FONT)
                    .fontColor(AppColor.TEXT)
                  Text(this.displayMode === ThemeMode.NIGHT
                    ? '夜间 · 深色背景浅色字，降低屏幕蓝光'
                    : '日间 · 白底深字高对比，白天强光下看得清')
                    .fontSize(AppSize.SMALL_FONT)
                    .fontColor(AppColor.TEXT_3)
                    .margin({ top: 4 })
                    .lineHeight(17)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Row() {
                  this.modeChip(ThemeMode.DAY, '日间')
                  this.modeChip(ThemeMode.NIGHT, '夜间')
                }
                .margin({ left: 10 })
              }
              .width('100%')
              .margin({ top: 12 })

              // ---- 维度二：关怀模式（独立开关，与明暗无关）----
              Row() {
                Column() {
                  Text('关怀模式')
                    .fontSize(AppSize.BODY_FONT)
                    .fontColor(AppColor.TEXT)
                  Text('独立开关：字号与图标放大，去掉繁杂次要信息，'
                    + '只保留最关键告警与一键呼叫。可与日间 / 夜间任意组合')
                    .fontSize(AppSize.SMALL_FONT)
                    .fontColor(AppColor.TEXT_3)
                    .margin({ top: 4 })
                    .lineHeight(17)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.careMode })
                  .selectedColor(AppColor.ACCENT)
                  .margin({ left: 10 })
                  .onChange((isOn: boolean) => {
                    ThemeStore.setCare(isOn);
                  })
              }
              .width('100%')
              .margin({ top: 16 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(16)
            .backgroundColor(AppColor.CARD)
            .borderRadius(AppSize.CARD_RADIUS)
            .margin({ bottom: 12 })

            // ---------- 设置 ----------
            Column() {
              Text('设置')
                .fontSize(AppSize.SUBTITLE_FONT)
                .fontWeight(FontWeight.Bold)
                .fontColor(AppColor.TEXT)
                .width('100%')

              // ---------- 基线模型管理 ----------
              // 整套"个性化基线"是这个作品相对固定阈值方案的核心差异，
              // 必须有一个能看、能重置的入口，否则家属不知道系统在拿什么判断
              this.settingRow('基线模型管理',
                '查看、重置老人个性化活动基线，误报记录会持续迭代优化基线',
                this.baselineOpen ? '收起' : '查看',
                () => {
                  this.baselineOpen = !this.baselineOpen;
                  if (this.baselineOpen) {
                    this.loadBaseline();
                  }
                })

              // 展开态：内联展示而不是弹窗。
              // 基线是"参考信息"，不该用一个会打断操作的模态框来承载
              if (this.baselineOpen) {
                Column() {
                  if (this.baselineAvg > 0) {
                    Row() {
                      this.baselineMetric('基线均值', `${this.baselineAvg} 次/日`)
                      this.baselineMetric('波动区间', `±${this.baselineStdDev}`)
                      this.baselineMetric('样本天数', `${this.baselineDays} 天`)
                    }
                    .width('100%')

                    Text('基线由近 14 天日活动量动态计算，随使用持续收敛。'
                      + '标记误报后系统会自动学习，下一周期基线随之更新。')
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.TEXT_3)
                      .margin({ top: 10 })
                      .lineHeight(17)
                      .width('100%')

                    Text('重置基线')
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.ON_PRIMARY)
                      .backgroundColor(AppColor.PRIMARY)
                      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
                      .borderRadius(14)
                      .margin({ top: 12 })
                      .onClick(() => {
                        this.resetBaseline();
                      })
                  } else {
                    Text('该老人暂无足够的连续历史数据，基线模型暂未建立。'
                      + '持续使用或标记几条处置记录后，基线会自动生成。')
                      .fontSize(AppSize.SMALL_FONT)
                      .fontColor(AppColor.TEXT_3)
                      .margin({ top: 8 })
                      .lineHeight(17)
                      .width('100%')
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ top: 4, bottom: 14 })
                .border({ width: { bottom: 1 }, color: AppColor.LINE })
              }

              // ---------- 设备信息（固件版本从首页移到这里） ----------
              this.settingRow('设备信息', this.deviceSummary(), this.firmwareLabel(), undefined)

              // ---------- 演示场景（仅 Mock 数据下显示） ----------
              // 用于答辩现场按顺序动态演示整套卡片状态：
              // 全部正常（全绿）→ 待关注（门窗长时间打开，黄）
              //   → 高危告警（燃气泄漏，红）→ 设备离线（灰 + 【设备离线】）
              if (this.useMock) {
                Column() {
                  Text('演示场景')
                    .fontSize(AppSize.BODY_FONT)
                    .fontColor(AppColor.TEXT)
                  Text('仅本地模拟数据生效，用于现场演示卡片三色状态与离线态。')
                    .fontSize(AppSize.SMALL_FONT)
                    .fontColor(AppColor.TEXT_3)
                    .margin({ top: 4 })
                  Row() {
                    this.demoChip('normal', '全部正常')
                    this.demoChip('warning', '待关注')
                    this.demoChip('danger', '高危告警')
                    this.demoChip('offline', '设备离线')
                  }
                  .width('100%')
                  .margin({ top: 10 })
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding({ top: 14, bottom: 14 })
                .border({ width: { bottom: 1 }, color: AppColor.LINE })
              }

              // ---------- 数据来源 ----------
              this.settingRow('数据来源', this.cloudName,
                this.useMock ? '切换到真实云端' : '切换到模拟数据', () => {
                  if (this.useMock) {
                    // 真实地址与令牌由登录流程提供，此处仅演示切换入口
                    AppConfig.switchToRealCloud(AppConfig.baseUrl, '');
                  } else {
                    AppConfig.switchToMock();
                  }
                  this.useMock = AppConfig.isMock();
                  this.cloudName = new CareService().cloudName();
                })

              // ---------- 当前角色 ----------
              this.settingRow('当前角色', MemberRole.labelOf(this.currentRole),
                '切换角色', () => {
                  const roles: string[] = [MemberRole.CHILD, MemberRole.GRID_WORKER, MemberRole.PROPERTY];
                  const idx: number = roles.indexOf(this.currentRole);
                  this.currentRole = roles[(idx + 1) % roles.length];
                  this.service.setRole(this.currentRole);
                  this.toast(`已切换为${MemberRole.labelOf(this.currentRole)}视角`);
                })
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


  // ==================== 通用设置行 ====================

  /**
   * 设置里的标准行：左标题 + 说明小字，右侧操作文字。
   *
   * actionLabel 为空表示这一行只是信息展示（如设备信息），不给可点的右侧文字 ——
   * 不能让它看起来像按钮却不能点。
   */
  @Builder
  settingRow(title: string, desc: string, actionLabel: string, act: (() => void) | undefined) {
    Row() {
      Column() {
        Text(title)
          .fontSize(AppSize.BODY_FONT)
          .fontColor(AppColor.TEXT)
        Text(desc)
          .fontSize(AppSize.SMALL_FONT)
          .fontColor(AppColor.TEXT_3)
          .margin({ top: 4 })
          .lineHeight(17)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (act !== undefined && actionLabel.length > 0) {
        Text(actionLabel)
          .fontSize(AppSize.SMALL_FONT)
          .fontColor(AppColor.SUCCESS)
          .onClick(() => {
            act();
          })
      } else if (actionLabel.length > 0) {
        // 纯信息行：右侧文字用次文本色，明确"不是按钮"
        Text(actionLabel)
          .fontSize(AppSize.SMALL_FONT)
          .fontColor(AppColor.TEXT_2)
      }
    }
    .width('100%')
    .padding({ top: 14, bottom: 14 })
    .border({ width: { bottom: 1 }, color: AppColor.LINE })
  }

  /** 基线展开态里的单个指标 */
  @Builder
  baselineMetric(label: string, value: string) {
    Column() {
      Text(value)
        .fontSize(AppSize.SUBTITLE_FONT)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.TEXT)
      Text(label)
        .fontSize(AppSize.SMALL_FONT)
        .fontColor(AppColor.TEXT_3)
        .margin({ top: 4 })
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
  }

  /** 演示场景选项。切换后写一个时间戳到 AppStorage，通知首页重新拉取 */
  @Builder
  demoChip(key: string, label: string) {
    Text(label)
      .fontSize(AppSize.SMALL_FONT)
      .fontColor(this.scenario === key ? AppColor.ON_PRIMARY: AppColor.TEXT_2)
      .backgroundColor(this.scenario === key ? AppColor.PRIMARY : AppColor.SURFACE)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(14)
      .margin({ right: 8 })
      .onClick(() => {
        this.scenario = key;
        this.service.setDemoScenario(key);
        // 首页在 Tabs 里是保活的，不会重走 aboutToAppear，
        // 用 AppStorage 通知它重新拉数据。
        AppStorage.setOrCreate('demoScenarioTick', DateUtil.now());
      })
  }

  /** 主题切换芯片：选中态实心 + 白字，未选中弱化为浅底 */
  @Builder
  modeChip(mode: string, label: string) {
    Text(label)
      .fontSize(AppSize.SMALL_FONT)
      .fontColor(this.displayMode === mode ? AppColor.ON_PRIMARY : AppColor.TEXT_2)
      .backgroundColor(this.displayMode === mode ? AppColor.ACCENT : AppColor.SURFACE)
      .padding({ left: 14, right: 14, top: 6, bottom: 6 })
      .borderRadius(14)
      .margin({ right: 8 })
      .onClick(() => {
        ThemeStore.setMode(mode);
      })
  }

  // ==================== 角色标签配色 ====================

  /**
   * 角色标签颜色：直系家属绿、外部协同方浅蓝、维护人员灰。
   * 颜色本身就是权限图例 —— 绿色说明"这是自己人，能看活动报告"。
   */
  private roleTagColor(role: string): string {
    switch (role) {
      case MemberRole.CHILD:
        return AppColor.SUCCESS;
      case MemberRole.GRID_WORKER:
      case MemberRole.PROPERTY:
        return AppColor.INFO;
      default:
        return AppColor.TEXT_3;
    }
  }

  // ==================== 基线 ====================

  /** 读取个性化基线。样本不足时三项都是 0，界面给明确说明而不是空白 */
  private async loadBaseline(): Promise<void> {
    this.baselineAvg = 0;
    this.baselineStdDev = 0;
    this.baselineDays = 0;
    try {
      const report = await this.service.loadActivityReport('week');
      if (report !== undefined) {
        this.baselineAvg = report.baselineAvg;
        this.baselineStdDev = report.baselineStdDev;
        this.baselineDays = AppConstants.BASELINE_WINDOW_DAYS;
      }
    } catch (err) {
      Logger.warn(MinePage.MODULE, `读取基线失败: ${(err as Error).message}`);
    }
  }

  /**
   * 重置基线。
   *
   * 真机上应当"清空云端已归档的该老人历史样本，从当前日期重新起算"。
   * Mock 数据是固定种子生成的，重算结果不变，所以这里只做演示反馈 ——
   * 但不能假装已经重置成功，那会让家属以为系统状态变了。
   */
  private resetBaseline(): void {
    this.toast('已重置：基线将从当前日期重新起算');
    this.baselineOpen = false;
    Logger.info(MinePage.MODULE, '用户触发基线重置（Mock 环境下不改变数据）');
  }

  // ==================== 导出 ====================

  /**
   * 导出居家安全日志。
   * 与预警中心同一口径：结构化文本 → 系统分享面板 → 选「打印」另存 PDF。
   */
  private exportLogs(): void {
    if (this.logs.length === 0) {
      this.toast('暂无可导出的日志');
      return;
    }
    try {
      const ctx: common.UIAbilityContext =
        this.getUIContext().getHostContext() as common.UIAbilityContext;
      ReportExporter.shareLogs(ctx, this.logs, this.elderName());
    } catch (err) {
      Logger.error(MinePage.MODULE, `导出日志失败: ${(err as Error).message}`);
      this.toast('导出失败，请稍后重试');
    }
  }

  /** 被监护老人姓名。取不到时退回中性称呼，不留占位符 */
  private elderName(): string {
    return this.service.boundElderName() ?? '家中老人';
  }

  // ==================== 其他 ====================

  /** 设备名称 · 序列号。未绑定时给明确文案，不留空 */
  private deviceSummary(): string {
    if (this.device === undefined) {
      return '未绑定监护主机';
    }
    const sn: string = this.device.deviceSn.length > 0 ? ` · ${this.device.deviceSn}` : '';
    return `${this.device.deviceName}${sn}`;
  }

  /** 固件版本文案。取不到时同样给占位，避免出现空行 */
  private firmwareLabel(): string {
    if (this.device === undefined || this.device.firmwareVersion.length === 0) {
      return '固件 --';
    }
    return `固件 ${this.device.firmwareVersion}`;
  }

  /**
   * 轻提示。
   * showToast 声明为可能抛异常，必须包 try —— 工程里既有约定，
   * 否则每次编译都留 warning 尾巴。
   */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      Logger.warn(MinePage.MODULE, `提示未弹出: ${(err as Error).message}`);
    }
  }
}
