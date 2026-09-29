# 시장 조사 (2026년 9월)

## 일반 노치 앱

| 앱 | 가격 | 공개 여부 | 특징 | 불만 |
|---|---|---|---|---|
| NotchNook | $25 또는 월 $3 | 비공개 | 가장 매끈함, 파일 트레이, 미러 | 배터리·CPU (대기 10~15%로 보고됨), 멀티 모니터 |
| Alcove | 약 $15 | 비공개 | 애니메이션이 가장 좋음 | 기능이 적음 |
| boring.notch | 무료 | GPL, 별 10.9k | 음악, 파일 선반, HUD 대체 | 다듬음이 부족 |
| Atoll | 무료 | GPL, 별 4.8k | 시스템 상태, 타이머, 클립보드 | 노치 있는 맥만 |

## AI 코딩 에이전트용 노치 앱 (직접 경쟁)

| 앱 | 가격 | 공개 여부 | 특징 |
|---|---|---|---|
| Vibe Island | $19.99 | 비공개 | 에이전트 25~30종, 권한 승인, 터미널 이동, 사용량 |
| CodeIsland | 무료 | MIT, 별 2.4k | 30개 이상 도구, 유닉스 소켓 훅, 아이폰·워치 앱 |
| Claude Island | 무료 | Apache, 별 2.5k | Claude Code만, 개발 멈춤 (2026-04) |

## 플랫폼 사실
- macOS 26은 **아이폰의** Live Activity를 메뉴 막대에 보여준다. 맥 앱이 스스로 Live Activity를 띄울 수는 없다. 그래서 아이폰 앱이 Live Activity를 띄우면 맥에도 보이는 우회로가 있다 (13 Pro Max 계획과 연결됨).
- MediaRemote는 macOS 26에서도 막혀 있다. 우회 방법은 `/usr/bin/perl`을 통하는 mediaremote-adapter(Developer ID 서명 필요)나 AppleScript다.

## Dynamic Notch의 차별점 / 할 일
1. **캐릭터와 저전력**: Clawd 애니메이션을 Core Animation 스프라이트로 돌려서, 계속 떠 있어도 CPU가 약 1%다. 측정값을 공개한다 (경쟁 앱의 가장 큰 불만이 배터리).
2. **한도 예측**: 지금 속도라면 언제 5시간 한도에 닿는지 보여준다 (구현함).
3. **완료 후 diff·테스트 요약**을 노치에서 보여준다 (예정).
4. **아이폰 Live Activity**로 맥 메뉴 막대·아이폰·워치에 동시에 표시한다 (예정, 13 Pro Max).
5. 노치 밖에서도: 카메라·마이크·원격 접속 같은 보안 표시, 다운로드 알림.

출처: notchy.dev, brow-app.com, getdroppy.app, vibeisland.app, github.com/wxtsky/CodeIsland, github.com/TheBoredTeam/boring.notch, github.com/Ebullioscopic/Atoll, support.apple.com/en-us/120684, github.com/ungive/mediaremote-adapter
