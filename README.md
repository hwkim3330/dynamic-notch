# Dynamic Notch

맥북 노치를 다이나믹 아일랜드처럼 쓰는 앱.
[Dynamic Notch 컨셉 영상](https://www.youtube.com/watch?v=YSvMAV2Ni3s)을 macOS에서 실제로 동작하게 만들었다.

![demo](docs/demo.gif)

1080p 데모 영상은 [Releases](https://github.com/hwkim3330/dynamic-notch/releases)에 있다.

## 기능

| 활동 | 동작 |
|---|---|
| ✳️ **Claude Code** | 작업 중이면 노치 왼쪽에서 Clawd가 걷고, 오른쪽에 경과 시간이 나온다. 권한이 필요하면 "확인 필요" 배너(Clawd가 손 흔들며 `!`), 끝나면 "작업 완료" 배너(깡총)를 띄운다. 펼치면 세션 목록이 보이고, 행을 누르면 그 세션의 터미널로 이동한다 |
| `>_` **Codex** | Codex 데스크톱 앱과 CLI 모두 지원. `~/.codex/sessions` 로그를 읽기만 해서 Codex 설정은 건드리지 않는다. 작업 중이면 노치에 표시하고, 승인이 필요하거나 끝나면 알린다 |
| 🪟 **여러 창** | 세션마다 터미널 tty를 기억한다. 펼친 목록에서 누르면 Terminal/iTerm2의 바로 그 탭으로 이동한다 (그 밖의 터미널은 앱만 앞으로 가져온다) |
| ⬇️ **다운로드** | Chrome, Safari 등 브라우저와 상관없이 `~/Downloads`에 파일 받기가 끝나면 알린다. 누르면 Finder에서 보여준다 |
| 🖥 **RustDesk** | 누군가 이 맥에 원격 접속하면 빨간 표시로 알린다 |
| 📊 **사용량** | 5시간·주간 구독 한도(%)와 초기화까지 남은 시간, 오늘/5시간/7일 토큰을 API 가격으로 환산한 금액, 24시간 막대, 모델별 합계, Codex 토큰을 보여준다. 5시간 한도가 80%·95%를 넘으면 알린다 |
| 📷 **미러** | 노치(카메라 자리)에서 바로 내장 카메라 미리보기를 연다. 미러를 연 동안에만 카메라가 켜진다 |
| 🟢 **카메라·마이크 감지** | 다른 앱이 카메라나 마이크를 켜고 끄면 노치에 표시한다 |
| 🎵 **음악** | Music, Spotify 재생 중이면 앨범아트와 파형이 나오고, 펼치면 플레이어가 된다 |
| 🔌 **전원** | 어댑터 연결/분리, 배터리 20% 이하 경고 |
| 🔓 **잠금 해제** | 자물쇠가 열리는 애니메이션 |
| 📞 **전화 · Face ID** | 영상 속 장면. 데모에서만 나온다 |

- 아무 활동이 없을 때 노치에 마우스를 올리면 Clawd와 미러 버튼만 살짝 나온다. 누르면 펼쳐진다. 화면 위쪽 가운데로 마우스를 옮길 때마다 큰 판이 튀어나와 가리지 않게 하기 위해서다.
- 활동 중(음악, Claude)일 때는 호버하면 바로 펼쳐지고, 마우스가 벗어나거나 다른 곳을 클릭하면 접힌다.
- 노치 크기는 `NSScreen.auxiliaryTopLeftArea/RightArea`로 실측한다. 모양과 크기는 스프링으로 모핑되고, 노치 밖은 클릭이 그대로 통과한다.
- Clawd는 [ClaudeAnimationBase](https://github.com/JohnHeibel/ClaudeAnimationBase)(MIT)의 `clawd.js` 실루엣과 포즈(idle, walk, hop, wave, sleep)를 SwiftUI Canvas로 옮겼다.

## 성능

노치에 몇 시간씩 떠 있는 작은 애니메이션(Clawd, 파형)은 프레임을 한 번 미리 그려 두고 Core Animation 키프레임으로 돌린다. 재생은 WindowServer가 하고 앱은 쉰다.

| 상태 | CPU (M4 Max) |
|---|---|
| Claude 작업 중 표시 (Clawd가 계속 걸음) | 약 1.1% |
| 변경 전 (SwiftUI로 매 프레임 그림) | 약 8~10% |

화면이 꺼지거나 잠기면 애니메이션과 마우스 추적을 멈춘다. 전체 화면 앱(영상 등)에서는 계속 떠 있는 표시를 숨기고, 잠깐 뜨는 알림만 보여준다.

시장 조사: [docs/research-2026-09.md](docs/research-2026-09.md)

## Claude Code 연결

`~/.claude/settings.json`에 훅을 넣는다. 앱 실행 파일이 훅 모드로 이벤트를 받아서 실행 중인 앱에 분산 알림으로 넘긴다. 훅은 `async`라서 Claude Code를 느리게 만들지 않는다.

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "async": true, "timeout": 5,
      "command": "H=\"$HOME/Applications/DynamicNotch.app/Contents/MacOS/DynamicNotch\"; [ -x \"$H\" ] && \"$H\" --claude-hook 2>/dev/null || true" }] }],
    "PreToolUse":  [{ "matcher": "*", "hooks": [ "…같은 명령…" ] }],
    "Notification": [ "…" ], "Stop": [ "…" ], "SessionEnd": [ "…" ]
  }
}
```

구독 한도는 Claude Code 상태 줄 JSON의 `rate_limits`에서만 공식적으로 얻을 수 있다. 그래서 상태 줄도 앱으로 연결한다. 터미널 아래에 `Opus 5.5 · 5h 42% (1h23m) · 주간 31%` 같은 한 줄이 생긴다.

```json
"statusLine": { "type": "command", "refreshInterval": 60,
  "command": "H=\"$HOME/Applications/DynamicNotch.app/Contents/MacOS/DynamicNotch\"; [ -x \"$H\" ] && \"$H\" --statusline 2>/dev/null || true" }
```

## 빌드 / 실행

```sh
./scripts/build-app.sh          # 빌드 → ~/Applications/DynamicNotch.app 설치 → 실행
./scripts/build-app.sh --demo   # 실행하면서 영상 속 장면을 데모로 재생
```

Xcode 26 / Swift 6.3, macOS 14 이상 (Apple Silicon)이 필요하다. 서명은 ad-hoc이다.

처음 쓸 때 묻는 권한:
- **자동화 (Music / Spotify)**: 앨범아트, 재생 위치, 재생 제어에 쓴다
- **카메라**: 미러를 처음 열 때만 묻는다

> macOS 15.4부터 서드파티 앱의 MediaRemote 접근이 막혔다. 그래서 Music과 Spotify가 보내는 분산 알림을 듣고, 필요한 정보는 AppleScript로 가져온다. 브라우저(YouTube 등)에서 재생 중인 미디어는 아직 표시되지 않는다.

## 구조

```
Sources/
  NotchKit/          플랫폼 공용 (macOS + iOS) — SwiftUI만 사용
    NotchShape.swift   애니메이션되는 노치 모양
    NotchModel.swift   상태, 우선순위, 활동별 레이아웃
    NotchView.swift    모핑, 블러 전환, 번짐, 탭
    Clawd.swift        Clawd 캐릭터 (Canvas, 기분별 포즈)
    ClaudeViews.swift  Claude 세션/배너, 살짝보기, 미러 판
    ActivityViews.swift 음악/통화/전원/카메라 감지/Face ID 뷰
    Demo.swift         데모 시퀀스, 앨범아트 색 추출
  DynamicNotch/      macOS 앱
    NotchPanel.swift   노치 위 투명 패널, 클릭 통과 처리
    NowPlayingProvider.swift  Music/Spotify
    ClaudeProvider.swift      Claude Code 훅 수신 (--claude-hook)
    CameraMirror.swift        카메라 미러 (AVCapture)
    SystemProviders.swift     전원, 잠금 해제, 카메라·마이크 사용 감지
```

## iPhone 13 Pro Max

[docs/iphone-13-pro-max.md](docs/iphone-13-pro-max.md) 참고. `NotchKit`은 iOS에서도 빌드되도록 구성돼 있다.

## License

MIT
