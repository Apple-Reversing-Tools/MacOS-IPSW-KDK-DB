# macOS Kernel Debug Kit Extractor

macOS Kernel Debug Kit (.pkg 파일)을 추출하고 분석하기 위한 도구 모음입니다.

## 파일 구성

- `kdk_extractor.sh` - 통합 Kernel Debug Kit 추출 및 분석 스크립트
- `README.md` - 이 문서

## 주요 기능

### kdk_extractor.sh - 통합 추출 및 분석기

macOS의 Kernel Debug Kit 패키지를 추출하고 분석하는 통합 스크립트입니다.

#### 사용법
```bash
# 추출
./kdk_extractor.sh extract Kernel_Debug_Kit_26_build_25A5349a.pkg

# 분석
./kdk_extractor.sh analyze Kernel_Debug_Kit_26_build_25A5349a/

# 도움말
./kdk_extractor.sh help
```

#### 지원하는 형식
- **pbzx 압축**: Apple의 pbzx 압축 형식
- **gzip 압축**: 표준 gzip 압축
- **xz 압축**: XZ 압축 형식
- **bzip2 압축**: Bzip2 압축 형식
- **AppleArchive**: Apple의 새로운 아카이브 형식
- **cpio 아카이브**: 표준 cpio 형식

## 기술적 원리

### 1. macOS 패키지 구조 이해

macOS의 Kernel Debug Kit은 다음과 같은 구조를 가집니다:

```
Kernel_Debug_Kit_xxx.pkg
├── Distribution          # 패키지 메타데이터
├── Resources/            # 설치 리소스
├── KDK.pkg              # 메인 커널 디버그 킷
│   ├── Bom              # 파일 목록
│   ├── PackageInfo      # 패키지 정보
│   └── Payload          # 실제 파일들 (압축됨)
└── KDK_SDK.pkg          # SDK 관련 파일들
    ├── Bom
    ├── PackageInfo
    └── Payload
```

### 2. 압축 형식 분석

#### pbzx 형식
- Apple이 개발한 압축 형식
- 매직 바이트: `pbzx`
- 헤더 구조:
  ```
  pbzx\0\0\0\0    # 매직 바이트 + 패딩
  flags (8 bytes)  # 플래그 정보
  unknown (8 bytes) # 추가 정보
  chunk_size (8 bytes) # 청크 크기
  chunk_data (lzma)   # 압축된 데이터
  ```

#### 추출 과정
1. `xar` 도구로 .pkg 파일을 임시 디렉토리에 추출
2. Payload 파일의 매직 바이트를 확인하여 압축 형식 판별
3. 적절한 압축 해제 도구 사용:
   - `pbzx`: pbzx 형식용
   - `gunzip`: gzip 형식용
   - `xz -d`: xz 형식용
   - `bzip2 -d`: bzip2 형식용
   - `aa`: AppleArchive 형식용
4. `cpio`로 최종 아카이브 해제

### 3. 스크립트의 핵심 로직

#### extract_stream 함수
```bash
extract_stream(){ # $1: payload.bin (또는 단일 Payload)
  local f="$1" t magic
  
  # AppleArchive 형식 확인
  if is_aar "$f"; then
    aa extract -d . "$f"
    return 0
  fi
  
  # 매직 바이트 직접 확인 (pbzx)
  magic="$(head -c 4 "$f" 2>/dev/null || true)"
  if [ "$magic" = "pbzx" ]; then
    pbzx - < "$f" | cpio -idm
    return 0
  fi
  
  # file 명령어로 형식 확인 후 처리
  t="$(file -b "$f" 2>/dev/null || true)"
  if echo "$t" | grep -qi gzip; then
    gunzip -dc "$f" | cpio -idm
  # ... 기타 형식들
  fi
}
```

#### extract_payload_dir 함수
- 분할된 Payload 파일들을 하나로 합침
- Archive.pax.* 파일 처리
- 적절한 출력 디렉토리에 파일 추출

### 4. macOS 호환성 문제 해결

#### mapfile 명령어 문제
- macOS 기본 bash 3.2는 `mapfile`을 지원하지 않음
- 해결책: `while read` 루프로 대체
```bash
# 기존 (bash 4.0+)
mapfile -t parts < <(ls -1 "$d"/Contents/Payload* | sort)

# 수정 (bash 3.2 호환)
while IFS= read -r part; do
  parts+=("$part")
done < <(ls -1 "$d"/Contents/Payload* | sort)
```

#### pbzx 도구 설치
- Homebrew를 통해 `pbzx` 도구 설치
- stdin에서 읽기: `pbzx - < file`

### 5. 추출 결과

성공적인 추출 후 다음 구조가 생성됩니다:

```
Kernel_Debug_Kit_26_build_25A5349a/
├── Distribution
├── Resources/
├── KDK.pkg/
├── KDK_SDK.pkg/
├── KDK_extracted/          # 메인 추출 결과
│   ├── KDK_ReadMe.rtfd/
│   └── System/
│       └── Library/
│           └── Kernels/
│               ├── kernel.release.t6030
│               ├── kernel.release.vmapple.dSYM/
│               └── kernel.release.t8122.dSYM/
└── KDK_SDK_extracted/      # SDK 추출 결과
    ├── System/
    └── usr/
```

## 필요 도구

- `xar` - 패키지 추출
- `cpio` - 아카이브 해제
- `pbzx` - Apple pbzx 압축 해제 (brew install pbzx)
- `file` - 파일 형식 확인
- `gunzip`, `xz`, `bzip2` - 기타 압축 해제
- `aa` - AppleArchive 해제 (선택사항)

## 설치 방법

```bash
# 필요 도구 설치
brew install xar pbzx

# 스크립트 실행 권한 부여
chmod +x kdk_extractor.sh
```

## 사용 예시

```bash
# 1. Kernel Debug Kit 추출
./kdk_extractor.sh extract Kernel_Debug_Kit_26_build_25A5349a.pkg

# 2. 추출된 파일들 자동 분석
./kdk_extractor.sh analyze Kernel_Debug_Kit_26_build_25A5349a/

# 3. 현재 디렉토리에서 자동으로 *_extracted 폴더 찾아서 분석
./kdk_extractor.sh analyze .

# 4. 도움말 보기
./kdk_extractor.sh help
```

## 새로운 기능

### 자동 분석 기능
추출 완료 후 자동으로 다음 분석을 수행합니다:

- **커널 파일 분석**: 아키텍처, 파일 정보 확인
- **dSYM 분석**: 디버그 심볼 정보 추출
- **시스템 정보**: 빌드 정보, 버전 정보 추출

## 주의사항

- macOS 26의 Kernel Debug Kit은 pbzx 압축을 사용합니다
- 추출 과정에서 임시 파일들이 생성되므로 충분한 디스크 공간이 필요합니다
