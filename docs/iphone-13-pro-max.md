# iPhone 13 Pro Max 계획

13 Pro Max는 다이나믹 아일랜드가 아니라 **노치**가 있는 폰이라, 영상 속 "Dynamic Notch" 컨셉과 딱 맞는 기기다.

## 제약

- iOS는 다른 앱 위나 상태 막대 위에 그리는 것을 허용하지 않는다. 그래서 순정 iOS에서 **시스템 전체에 뜨는 노치**는 불가능하다.
- ActivityKit(Live Activity)은 13 Pro Max에서 잠금 화면 배너로만 나오고, 노치 주변으로는 나오지 않는다.

## 할 수 있는 것

1. **앱 안 Dynamic Notch** — `NotchKit`을 그대로 쓰는 iOS 앱. 전체 화면(상태 막대 숨김)에서 실제 노치 위치에 `NotchView`를 올린다.
   - 13 Pro Max 노치: 약 **210 × 32 pt** (화면 428 × 926 pt, safe area top 47 pt)
   - 음악(MPMusicPlayerController / MPNowPlayingInfoCenter), 배터리(UIDevice), 볼륨(AVAudioSession.outputVolume KVO), Face ID(LocalAuthentication)를 실제로 연결할 수 있다
2. **탈옥 트윅** — 탈옥한 13 Pro Max라면 SpringBoard 트윅(Theos)으로 시스템 전체에 적용할 수 있다. UI는 `NotchKit` SwiftUI 뷰를 그대로 재사용한다.

## 준비된 것

- `Package.swift`에 `.iOS(.v17)` 플랫폼이 들어 있다
- `NotchKit`은 AppKit에 의존하지 않는다 (SwiftUI + CoreGraphics + CoreImage만 사용)
- 데모 시퀀스 `NotchDemo.run(model)`은 iOS에서도 그대로 돈다

다음 단계: `ios/` 폴더에 앱 타깃(XcodeGen 또는 Xcode 프로젝트)을 만들고 `model.notchSize = CGSize(width: 210, height: 32)`로 설정하기.
