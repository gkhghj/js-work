/**
 * @file    IotDaSecret.example.ets
 * @brief   华为云 IAM 凭据模板（占位符，可提交）
 *
 * 使用方法：
 *   1. 复制本文件为 IotDaSecret.ets（同目录）
 *   2. 把三个字段填成自己的值
 *
 * IotDaSecret.ets 已在 .gitignore 中，不会进仓库。
 *
 * 字段来源（华为云控制台）：
 *   DOMAIN_NAME —— 「我的凭证 → API 凭证」第一屏的账号名
 *   USER_NAME   —— 「统一身份认证 → 用户」里的 IAM 子用户名
 *   PASSWORD    —— 该子用户的登录密码
 *
 * 为什么必须用子用户而不是主账号：
 *   主账号属于华为账号体系，密码不走 IAM 的密码认证，
 *   调 /v3/auth/tokens 会一直 401。子用户是纯 IAM 用户，密码认证可用。
 */

export class IotDaSecret {
  /** 华为云账号名（注意末尾是 - 不是 _）*/
  static readonly DOMAIN_NAME: string = '';

  /** IAM 子用户名 */
  static readonly USER_NAME: string = '';

  /** 子用户密码 */
  static readonly PASSWORD: string = '';
}
