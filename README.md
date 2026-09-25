# Dynamic Notch

맥북 노치를 다이나믹 아일랜드처럼 쓰는 앱.
[Dynamic Notch 컨셉 영상](https://www.youtube.com/watch?v=YSvMAV2Ni3s)을 macOS에서 실제로 동작하게 만들었다.

![demo](docs/demo.gif)

## 기능

| 활동 | 동작 | 데이터 출처 |
|---|---|---|
| 🎵 재생 중 | 노치 좌우로 앨범아트 + 파형(아트 색). 마우스를 올리면 플레이어(진행 막대, 이전/재생/다음)로 펼쳐짐 | Music, Spotify |
| 🔊 볼륨 | 볼륨 또는 음소거가 바뀌면 노치에 막대 표시 | CoreAudio |
| 🔋 충전 | 어댑터 연결/분리, 배터리 20% 이하 경고 | IOKit |
| 🔓 잠금 해제 | 자물쇠가 열리는 애니메이션 | 화면 잠금 해제 알림 |
| 🎧 블루투스 | AirPods 등이 연결/해제되면 표시 | IOBluetooth |
| 📞 전화 · Face ID | 영상 속 수신 화면 → 통화 중 타이머 + 파형, Face ID 스캔 → 성공 | 데모 전용 |
| 🏠 홈 | 재생 중이 아닐 때 노치에 호버하면 날짜, 시각, 볼륨, 배터리 링 표시 | |

- 노치 크기는 `NSScreen.auxiliaryTopLeftArea/RightArea`로 실측해서 정확히 맞춘다. 노치가 없는 외부 모니터에서는 가상 노치를 쓴다.
- 모양은 위쪽이 오목하게 퍼지는 `NotchShape`이고, 모서리 반지름과 크기가 스프링으로 모핑된다.
- 내용은 블러 페이드로 전환되고, 활동 색으로 아래쪽에 은은한 번짐이 생긴다.
- 노치 모양 밖은 클릭이 그대로 통과하고, 펼칠 때 트랙패드 햅틱이 온다.
- 전체 화면 앱과 모든 Spaces에 표시된다. 메뉴 막대 아이콘에서 데모 재생, 로그인 시 자동 실행, 종료를 할 수 있다.

## 빌드 / 실행

```sh
./scripts/build-app.sh          # 빌드 → ~/Applications/DynamicNotch.app 설치 → 실행
./scripts/build-app.sh --demo   # 실행하면서 영상 속 장면을 데모로 재생
```

Xcode 26 / Swift 6.3, macOS 14 이상 (Apple Silicon)이 필요하다. 서명은 ad-hoc이다.

처음 실행할 때 묻는 권한:
- **자동화 (Music / Spotify)**: 앨범아트, 재생 위치, 재생 제어에 쓴다
- **블루투스**: 기기 연결 알림에 쓴다 (거부해도 나머지 기능은 동작한다)

> macOS 15.4부터 서드파티 앱의 MediaRemote 접근이 막혔다. 그래서 Music과 Spotify가 보내는 분산 알림을 듣고, 필요한 정보는 AppleScript로 가져온다. 브라우저(YouTube 등)에서 재생 중인 미디어는 아직 표시되지 않는다.

## 구조

```
Sources/
  NotchKit/          플랫폼 공용 (macOS + iOS) — SwiftUI만 사용
    NotchShape.swift   애니메이션되는 노치 모양
    NotchModel.swift   상태, 우선순위, 활동별 레이아웃
    NotchView.swift    모핑, 블러 전환, 번짐
    ActivityViews.swift 음악/통화/볼륨/배터리/Face ID/홈 뷰
    Demo.swift         데모 시퀀스, 앨범아트 색 추출
  DynamicNotch/      macOS 앱
    NotchPanel.swift   노치 위 투명 패널, 클릭 통과 처리
    NowPlayingProvider.swift  Music/Spotify
    SystemProviders.swift     배터리, 볼륨, 잠금 해제, 블루투스
```

## iPhone 13 Pro Max

[docs/iphone-13-pro-max.md](docs/iphone-13-pro-max.md) 참고. `NotchKit`은 iOS에서도 빌드되도록 구성돼 있다.

## License

MIT
