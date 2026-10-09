# =============================================================================
# Stale file handle の検知（CloudWatch Logs のメトリクスフィルター＋アラーム）
#
#   ECS の awslogs ドライバが送っているロググループ（JBoss のコンソール出力・Log4j2 の
#   StatusLogger のエラーが入る）から "Stale file handle" を数え、1 回でも出たら通知する。
#   アプリのログファイルに書けなくなったときのエラーは、ファイルではなく標準エラー側に出るので、
#   EFS 上のファイルではなく CloudWatch Logs を監視するのが確実。
# =============================================================================
terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

variable "log_group_names" {
  description = "監視する ECS のロググループ（例: [\"/ecs/interapi\", \"/ecs/intra-api\"]）"
  type        = list(string)
}

variable "alarm_actions" {
  description = "アラーム時の通知先（SNS トピック ARN など）"
  type        = list(string)
  default     = []
}

variable "metric_namespace" {
  description = "メトリクスの名前空間"
  type        = string
  default     = "Custom/EFSLogs"
}

variable "period_seconds" {
  description = "集計の間隔（秒）"
  type        = number
  default     = 300
}

locals {
  metric_name = "StaleFileHandleCount"
}

resource "aws_cloudwatch_log_metric_filter" "stale_file_handle" {
  for_each = toset(var.log_group_names)

  name           = "stale-file-handle${replace(each.value, "/", "-")}"
  log_group_name = each.value
  # Java の例外メッセージは strerror(ESTALE) の "Stale file handle"（glibc 2.18 以降の表記）。
  # フィルターパターンは大文字小文字を区別する。正規表現（%...%）では ( ) と (?i) が使えないので完全一致の語句にする
  pattern = "\"Stale file handle\""

  metric_transformation {
    name          = local.metric_name
    namespace     = var.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "stale_file_handle" {
  alarm_name          = "efs-logs-stale-file-handle"
  alarm_description   = "Stale file handle（ESTALE）を検知。runbook: estale-diag.sh で該当タスクを調べ、消した側を止めてからタスクを入れ替える"
  namespace           = var.metric_namespace
  metric_name         = local.metric_name
  statistic           = "Sum"
  period              = var.period_seconds
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions

  depends_on = [aws_cloudwatch_log_metric_filter.stale_file_handle]
}

output "metric" {
  value = "${var.metric_namespace}/${local.metric_name}"
}
