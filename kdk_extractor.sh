#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# macOS Kernel Debug Kit Extractor & Analyzer
# 통합 버전: 추출 + 분석 기능을 하나의 스크립트로 제공
# =============================================================================

# 스크립트 디렉토리 설정
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------ 헬퍼 함수들 ------
have() { command -v "$1" >/dev/null 2>&1; }
req()  { have "$1" || { echo "[-] '$1' 필요. brew 또는 CLT로 설치하세요."; exit 1; }; }

# ------ 의존성 확인 ------
req file
req cpio
have xar    || { echo "[-] 'xar' 필요 (brew install xar)"; exit 1; }
have xz     || true
have bzip2  || true
req pbzx    # pbzx 도구 필수
have aa     || true   # AppleArchive extractor

# ------ AppleArchive 매직 확인 ------
is_aar(){ 
  local magic
  magic=$(head -c 4 "$1" 2>/dev/null | xxd -p -l 4 2>/dev/null | tr -d '\n' | tr '[:upper:]' '[:lower:]')
  [ "$magic" = "61617200" ]
}

# ------ 압축 스트림 추출 ------
extract_stream(){ # $1: payload.bin (또는 단일 Payload)
  local f="$1" t magic
  if is_aar "$f"; then
    have aa || { echo "[-] AppleArchive 감지. '/usr/bin/aa' 필요. (xcode-select --install)"; return 2; }
    aa extract -d . "$f"
    return 0
  fi
  
  # 매직 바이트 직접 확인
  magic="$(head -c 4 "$f" 2>/dev/null || true)"
  if [ "$magic" = "pbzx" ]; then
    pbzx - < "$f" | cpio -idm
    return 0
  fi
  
  t="$(file -b "$f" 2>/dev/null || true)"
  if   echo "$t" | grep -qi gzip;   then gunzip -dc "$f" | cpio -idm
  elif echo "$t" | grep -qi xz;     then xz -dc "$f" | cpio -idm
  elif echo "$t" | grep -qi bzip2;  then bzip2 -dc "$f" | cpio -idm
  elif echo "$t" | grep -qi pbzx;   then pbzx - < "$f" | cpio -idm
  elif echo "$t" | grep -qi cpio;   then cpio -idm < "$f"
  else
    echo "[-] 알 수 없는 Payload 타입: $t ($f)"
    return 2
  fi
}

# ------ 디렉터리 d에서 Payload*/Archive.pax.* 찾아 전개 ------
extract_payload_dir(){
  local d="$1" out_dir="${2:-}"
  # 1) Archive.pax.*
  if [ -f "$d/Contents/Archive.pax.gz" ]; then (cd "$d"; gunzip -dc Contents/Archive.pax.gz | cpio -idm); return 0; fi
  if [ -f "$d/Contents/Archive.pax.xz" ]; then (cd "$d"; xz -dc Contents/Archive.pax.xz | cpio -idm); return 0; fi
  if [ -f "$d/Archive.pax.gz" ]; then (cd "$d"; gunzip -dc Archive.pax.gz | cpio -idm); return 0; fi
  if [ -f "$d/Archive.pax.xz" ]; then (cd "$d"; xz -dc Archive.pax.xz | cpio -idm); return 0; fi

  # 2) Payload* (분할 가능) — 우선 Contents/, 없으면 루트
  local parts=() base tmp
  if compgen -G "$d/Contents/Payload*" >/dev/null; then
    # macOS 호환: mapfile 대신 while read 루프 사용
    while IFS= read -r part; do
      parts+=("$part")
    done < <(ls -1 "$d"/Contents/Payload* | sort)
  elif compgen -G "$d/Payload*" >/dev/null; then
    while IFS= read -r part; do
      parts+=("$part")
    done < <(ls -1 "$d"/Payload* | sort)
  fi
  if [ ${#parts[@]} -gt 0 ]; then
    tmp="$(mktemp -t payload.cat.XXXXXX)"
    cat "${parts[@]}" > "$tmp"
    if [ -n "$out_dir" ]; then
      mkdir -p "$out_dir"
      (cd "$out_dir"; extract_stream "$tmp")
    else
      (cd "$d"; extract_stream "$tmp")
    fi
    local exit_code=$?
    rm -f "$tmp"
    return $exit_code
  fi
  return 1
}

# ------ .pkg(파일/디렉토리) → outdir로 전개 (내부 *.pkg 재귀) ------
extract_pkg_any(){
  local in="$1" out="$2"
  mkdir -p "$out"
  if [ -d "$in" ]; then
    # bundle
    if extract_payload_dir "$in" "$out" || extract_payload_dir "$in/Contents" "$out"; then return 0; fi
    # 내부 *.pkg 재귀 (Contents/Packages, Resources, 루트)
    local found=0 inner
    shopt -s nullglob
    for inner in "$in"/Contents/Packages/*.pkg "$in"/Resources/*.pkg "$in"/*.pkg; do
      [ -e "$inner" ] || continue; found=1
      extract_pkg_any "$inner" "$out/$(basename "${inner%.pkg}")"
    done
    [ $found -eq 1 ] && return 0
    echo "[-] bundle에서 Payload/내부 *.pkg를 찾지 못함: $in"; return 2
  else
    # flat/product
    local tmp; tmp="$(mktemp -d -t kdk.xar.XXXXXX)"
    xar -xf "$in" -C "$tmp"
    if extract_payload_dir "$tmp" "$out"; then rm -rf "$tmp"; return 0; fi
    local found=0 inner
    shopt -s nullglob
    for inner in "$tmp"/*.pkg "$tmp"/Resources/*.pkg "$tmp"/Packages/*.pkg; do
      [ -e "$inner" ] || continue; found=1
      extract_pkg_any "$inner" "$out/$(basename "${inner%.pkg}")"
    done
    rm -rf "$tmp"
    [ $found -eq 1 ] && return 0
    echo "[-] flat/product에서 Payload/내부 *.pkg를 찾지 못함: $in"; return 2
  fi
}

# =============================================================================
# 분석 기능들
# =============================================================================

# ------ 커널 파일 정보 분석 ------
analyze_kernels() {
  local base_dir="${1:-.}"
  echo "=== 커널 파일 분석 ==="
  
  # 커널 파일들 찾기
  local kernel_files=()
  while IFS= read -r -d '' file; do
    kernel_files+=("$file")
  done < <(find "$base_dir" -name "kernel*" -type f -print0 2>/dev/null)
  
  if [ ${#kernel_files[@]} -eq 0 ]; then
    echo "[-] 커널 파일을 찾을 수 없습니다."
    return 1
  fi
  
  echo "[+] 발견된 커널 파일들:"
  for kernel in "${kernel_files[@]}"; do
    echo "  - $kernel"
    file "$kernel"
    if [ -x "$kernel" ]; then
      echo "    아키텍처: $(lipo -info "$kernel" 2>/dev/null || echo "알 수 없음")"
    fi
    echo
  done
}

# ------ dSYM 파일 분석 ------
analyze_dsyms() {
  local base_dir="${1:-.}"
  echo "=== dSYM 파일 분석 ==="
  
  # dSYM 디렉토리들 찾기
  local dsym_dirs=()
  while IFS= read -r -d '' dir; do
    dsym_dirs+=("$dir")
  done < <(find "$base_dir" -name "*.dSYM" -type d -print0 2>/dev/null)
  
  if [ ${#dsym_dirs[@]} -eq 0 ]; then
    echo "[-] dSYM 파일을 찾을 수 없습니다."
    return 1
  fi
  
  echo "[+] 발견된 dSYM 파일들:"
  for dsym in "${dsym_dirs[@]}"; do
    echo "  - $dsym"
    
    # Info.plist에서 정보 추출
    if [ -f "$dsym/Contents/Info.plist" ]; then
      echo "    UUID: $(plutil -extract CFBundleIdentifier raw "$dsym/Contents/Info.plist" 2>/dev/null || echo "알 수 없음")"
      echo "    버전: $(plutil -extract CFBundleShortVersionString raw "$dsym/Contents/Info.plist" 2>/dev/null || echo "알 수 없음")"
    fi
    
    # DWARF 파일 확인
    local dwarf_file="$dsym/Contents/Resources/DWARF/$(basename "$dsym" .dSYM)"
    if [ -f "$dwarf_file" ]; then
      echo "    DWARF 파일: $dwarf_file"
      if have dwarfdump; then
        echo "    심볼 수: $(dwarfdump --statistics "$dwarf_file" 2>/dev/null | grep -c "DW_TAG_" || echo "알 수 없음")"
      fi
    fi
    echo
  done
}

# ------ 시스템 정보 추출 ------
extract_system_info() {
  local base_dir="${1:-.}"
  echo "=== 시스템 정보 추출 ==="
  
  # Build 정보 찾기
  local build_files=()
  while IFS= read -r -d '' file; do
    build_files+=("$file")
  done < <(find "$base_dir" -name "*build*" -o -name "*version*" -o -name "*Build*" -type f -print0 2>/dev/null)
  
  if [ ${#build_files[@]} -eq 0 ]; then
    echo "[-] 빌드 정보 파일을 찾을 수 없습니다."
    return 1
  fi
  
  echo "[+] 빌드 정보 파일들:"
  for build_file in "${build_files[@]}"; do
    echo "  - $build_file"
    if [[ "$build_file" == *.plist ]]; then
      echo "    내용:"
      plutil -p "$build_file" 2>/dev/null | head -10 | sed 's/^/      /'
    elif [[ "$build_file" == *.txt ]]; then
      echo "    내용:"
      head -5 "$build_file" | sed 's/^/      /'
    fi
    echo
  done
}

# ------ 전체 분석 실행 ------
run_full_analysis() {
  local base_dir="${1:-.}"
  
  echo "=========================================="
  echo "  macOS Kernel Debug Kit 분석 시작"
  echo "=========================================="
  echo
  
  analyze_kernels "$base_dir"
  echo
  
  analyze_dsyms "$base_dir"
  echo
  
  extract_system_info "$base_dir"
  
  echo "=========================================="
  echo "  분석 완료"
  echo "=========================================="
}

# =============================================================================
# 메인 함수들
# =============================================================================

# ------ 추출 함수 ------
extract_kdk() {
  local PKG="${1:-}"
  [ -n "$PKG" ] || { echo "Usage: $0 extract <Kernel_Debug_Kit_xxx.pkg>"; exit 1; }
  
  TOP="${PKG%.pkg}"
  mkdir -p "$TOP"
  echo "[+] 1단계: product pkg 풀기 → $TOP"
  xar -xf "$PKG" -C "$TOP"

  cd "$TOP"
  for inner in KDK.pkg KDK_SDK.pkg; do
    [ -e "$inner" ] || continue
    echo "[+] 2단계: 내부 $inner 전개"
    extract_pkg_any "$inner" "$(basename "${inner%.pkg}")_extracted"
  done

  echo "[+] 완료: $(pwd) 아래 *_extracted/ 에 실제 파일이 전개됩니다."
  
  # 추출 완료 후 자동 분석 실행
  echo
  run_full_analysis "."
}

# ------ 분석 함수 ------
analyze_extracted() {
  local target_dir="${1:-.}"
  
  if [ ! -d "$target_dir" ]; then
    echo "[-] 디렉토리를 찾을 수 없습니다: $target_dir"
    exit 1
  fi
  
  # *_extracted 디렉토리 찾기
  local extracted_dirs=()
  while IFS= read -r -d '' dir; do
    extracted_dirs+=("$dir")
  done < <(find "$target_dir" -name "*_extracted" -type d -print0 2>/dev/null)
  
  if [ ${#extracted_dirs[@]} -eq 0 ]; then
    echo "[-] *_extracted 디렉토리를 찾을 수 없습니다."
    echo "    먼저 추출을 실행하세요: $0 extract <package.pkg>"
    exit 1
  fi
  
  for dir in "${extracted_dirs[@]}"; do
    echo "분석 중: $dir"
    run_full_analysis "$dir"
    echo
  done
}

# ------ 사용법 출력 ------
show_usage() {
  cat << EOF
macOS Kernel Debug Kit Extractor & Analyzer

사용법:
  $0 extract <package.pkg>     - Kernel Debug Kit 추출
  $0 analyze [directory]       - 추출된 파일들 분석
  $0 help                      - 이 도움말 출력

예시:
  $0 extract Kernel_Debug_Kit_26_build_25A5349a.pkg
  $0 analyze Kernel_Debug_Kit_26_build_25A5349a/
  $0 analyze .                 # 현재 디렉토리에서 *_extracted 찾아서 분석

필요한 도구:
  - xar (brew install xar)
  - pbzx (brew install pbzx)
  - file, cpio (기본 설치)

선택적 도구:
  - dwarfdump (심볼 분석용)
  - lipo (아키텍처 정보용)
  - aa (AppleArchive 지원용)
EOF
}

# =============================================================================
# 메인 실행부
# =============================================================================

main() {
  local command="${1:-help}"
  
  case "$command" in
    "extract")
      shift
      extract_kdk "$@"
      ;;
    "analyze")
      shift
      analyze_extracted "${1:-.}"
      ;;
    "help"|"-h"|"--help")
      show_usage
      ;;
    *)
      echo "[-] 알 수 없는 명령어: $command"
      echo
      show_usage
      exit 1
      ;;
  esac
}

main "$@"
