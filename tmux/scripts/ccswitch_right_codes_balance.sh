#!/usr/bin/env bash
set -euo pipefail

url="https://www.right.codes/subscriptions/list"
unit="USD"
token_file="${CCSWITCH_TOKEN_FILE:-$HOME/.config/tmux/run/ccswitch_right_codes.token}"
token="${CCSWITCH_TOKEN:-}"
connect_timeout="${CCSWITCH_CONNECT_TIMEOUT:-3}"
max_time="${CCSWITCH_MAX_TIME:-10}"

pause() {
  if [[ "${CCSWITCH_NO_PAUSE:-0}" == "1" ]]; then
    return 0
  fi
  read -r -n 1 -s -p "按任意键关闭..." || true
  printf '\n'
}

loading_shown=0
show_loading() {
  if [[ "${CCSWITCH_DEBUG:-0}" == "1" ]]; then
    return 0
  fi
  if [[ ! -t 1 || "${TERM:-}" == "dumb" ]]; then
    return 0
  fi
  printf '%s' "right code 当日余额：loading..."
  loading_shown=1
}

clear_loading_line() {
  if ((loading_shown == 1)); then
    printf '\r\033[2K'
    loading_shown=0
  fi
}

print_value() {
  clear_loading_line
  printf '%s\n' "right code 当日余额：$1"
}

print_error() {
  clear_loading_line
  printf '%s\n' "right code 当日余额：N/A ${unit}"
  printf '%s\n' "error: $1"
}

if [[ -z "${token}" && -f "${token_file}" ]]; then
  token="$(<"${token_file}")"
fi

token="${token//$'\n'/}"
token="${token//$'\r'/}"

if ! command -v curl >/dev/null 2>&1; then
  print_error "curl 未安装"
  pause
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  print_error "python3 未安装"
  pause
  exit 0
fi

if [[ -z "${token}" ]]; then
  print_error "缺少 token（写入 ${token_file} 或设置 CCSWITCH_TOKEN 环境变量）"
  pause
  exit 0
fi

show_loading

tmp_dir="$(mktemp -d)"
tmp_body="${tmp_dir}/body"
tmp_headers="${tmp_dir}/headers"
trap 'rm -rf "${tmp_dir}" 2>/dev/null || true' EXIT

curl_rc=0
curl_meta="$(
  curl -sS \
    --connect-timeout "${connect_timeout}" \
    --max-time "${max_time}" \
    --retry 1 \
    --retry-delay 0 \
    --retry-max-time "${max_time}" \
    --retry-all-errors \
    -L \
    -D "${tmp_headers}" \
    -o "${tmp_body}" \
    -w "%{http_code}\n%{content_type}\n" \
    -H "Accept: application/json" \
    -H "Authorization: Bearer ${token}" \
    -H "User-Agent: cc-switch/1.0" \
    "${url}" \
    2>&1
)" || curl_rc=$?

http_code="$(printf '%s\n' "${curl_meta}" | sed -n '1p')"
content_type="$(printf '%s\n' "${curl_meta}" | sed -n '2p')"
resp="$(cat "${tmp_body}" 2>/dev/null || true)"

if ((curl_rc != 0)); then
  print_error "curl(${curl_rc}) ${curl_meta}"
  pause
  exit 0
fi

if [[ -z "${http_code}" || "${http_code}" == "000" ]]; then
  print_error "未获取到 HTTP 状态码"
  pause
  exit 0
fi

if [[ "${http_code}" != 2* ]]; then
  if [[ -n "${content_type}" ]]; then
    print_error "HTTP ${http_code} (${content_type})"
  else
    print_error "HTTP ${http_code}"
  fi
  pause
  exit 0
fi

if [[ "${CCSWITCH_DEBUG:-0}" == "1" ]]; then
  head_line="$(printf '%s' "${resp}" | tr '\r' '\n' | sed -n '1p')"
  printf '%s\n' "debug: http=${http_code} content-type=${content_type}"
  if [[ -n "${head_line}" ]]; then
    printf '%s\n' "debug: body_first_line: ${head_line:0:160}"
  fi
fi

parsed="$(
  python3 -c '
import json
import sys

unit = "USD"

def out(value: str, err: str = "") -> None:
  print(value)
  print(err)

text = sys.stdin.read()
try:
  data = json.loads(text)
except Exception as e:
  msg = str(e) or e.__class__.__name__
  out(f"N/A {unit}", f"响应不是合法 JSON: {msg}")
  sys.exit(0)

subs = data.get("subscriptions", None)
if not isinstance(subs, list):
  detail = (
    data.get("detail")
    or data.get("message")
    or data.get("error")
    or data.get("msg")
    or data.get("reason")
  )
  if isinstance(detail, (str, int, float)):
    out(f"N/A {unit}", str(detail))
  else:
    out(f"N/A {unit}", "subscriptions 不存在或不是数组")
  sys.exit(0)

total = 0.0
for item in subs:
  try:
    remaining = item.get("remaining_quota", 0)
    total += float(remaining or 0)
  except Exception:
    pass

s = f"{total:.2f}"
if s.endswith(".00"):
  s = s[:-3]
elif s.endswith("0"):
  s = s[:-1]

out(f"{s} {unit}", "")
' <<<"${resp}"
)"

value="$(printf '%s\n' "${parsed}" | sed -n '1p')"
err="$(printf '%s\n' "${parsed}" | sed -n '2p')"

print_value "${value}"
if [[ -n "${err}" ]]; then
  printf '%s\n' "error: ${err}"
fi
pause
