# herdr-space-branch

[English](README.md) | **한국어**

[herdr](https://herdr.dev) 의 spaces 사이드바가 첫 탭의 저장소가 아니라 **지금 보고 있는 pane** 의 브랜치를
표시하게 하는 플러그인.

## 왜 필요한가

herdr 0.9.0 은 워크스페이스의 git 정보를 **첫 번째 탭의 루트 pane** 에서 가져온다
(`src/workspace.rs` 의 `Workspace::resolved_identity_cwd_from`). `branch` 와 `git_status` 두 칸이 모두 그
디렉터리 하나에서 나오므로, 저장소가 둘 이상 섞인 워크스페이스는 한쪽만 계속 보여준다.

```
space: PIXELBOOST
├── tab: research-archive   (main)     ← 사이드바는 이걸 표시하고…
└── tab: homepage           (develop)  ← …작업은 여기서 한다
```

탭 순서를 바꾸거나 저장소별로 워크스페이스를 나누면 해결되지만, 매번 손으로 해야 한다.

## 동작

- `pane.focused`, `tab.focused`, `workspace.focused`, `pane.moved` 훅을 받는다.
- 한 번 돌 때 **모든 워크스페이스**를 갱신한다. 이벤트가 실어 온 워크스페이스만 고치면 안 된다 — 사이드바는
  워크스페이스마다 한 줄을 그리고, 그 안에서 탭을 바꾸면 그 줄이 가리켜야 할 저장소가 달라지기 때문이다.
  `herdr api snapshot` 한 번이면 각 워크스페이스의 활성 탭이 보여주는 pane 을 전부 알 수 있다.
- 그 pane 의 `foreground_cwd`(pane 시작 경로가 아니라 `cd` 를 따라간다)를 읽어
  `herdr workspace report-metadata` 로 워크스페이스 토큰 두 개를 보고한다.

  | 토큰 | 값 |
  |---|---|
  | `branch` | 현재 브랜치, HEAD 가 분리돼 있으면 `detached@<짧은 sha>` |
  | `git_status` | upstream 대비 `↑N ↓M`. 내장 칸과 같은 형식(`src/ui/sidebar.rs`)이고 둘 다 0이면 지운다 |

- 포커스된 pane 이 git 작업트리 안이 아니면 두 토큰을 **지운다.** 다른 pane 의 브랜치가 남아 오해를 주지 않도록.
- 보고마다 밀리초 시퀀스 번호를 실어, 이벤트가 뒤늦게 도착해도 옛 값이 되살아나지 않는다.
- 행을 다시 보고할지는 "무엇을 보고했었나" 기록이 아니라 herdr 에서 읽어 온 **사이드바에 실제로 떠 있는 값**과
  비교해 정한다. herdr 은 워크스페이스 토큰을 메모리에 들고 있어, 서버가 재시작되면(컴포지터가 크래시하면 같이
  죽는다) 토큰이 전부 사라지지만 이 플러그인의 상태 디렉터리는 디스크에 남는다. 기록과 비교하던 때는 재시작
  뒤 브랜치가 그대로인 행이 모두 빈 채로 남았다. 사이드바와 비교하면 데몬의 다음 틱에 돌아온다.
- 훅이 아예 닿지 않는 변화도 있다 — pane **안에서** 바꾼 브랜치는 herdr 이벤트가 없고, 탭 전환도 훅까지
  오지 않는 경우가 있다. 작은 데몬(`bin/watch`)이 둘 다 맡는다. `[[startup]]` 훅에서 분리해 띄우고, 떠 있지
  않으면 이벤트 훅이 다시 띄운다 — 이미 돌고 있는 서버에 설치한 경우도 이걸로 덮인다. `flock` 으로 하나만
  돌고, herdr 서버가 응답하지 않으면 종료한다(서버가 꺼져도 소켓 파일은 남을 수 있어, 스냅샷 3회 연속 무응답을
  신호로 쓴다).
  - 매 틱(2초) 비용은 스냅샷 한 번과 워크스페이스별 HEAD 파일 `stat` 한 번이다. 보이는 저장소나 HEAD 가
    실제로 바뀌었을 때만 `git` 을 돌리고 herdr 을 부른다. 15틱마다 ahead/behind 는 그냥 다시 계산한다 —
    fetch·push 는 HEAD 가 그대로여도 값이 바뀌기 때문이다.
  - 두 숫자는 설정으로 바꿀 수 있다(아래 설정 절).
- 워크스페이스 행이 따라가는 pane 은 ① 지금 포커스된 pane, ② 그 워크스페이스에서 마지막으로 포커스했던
  pane(워크스페이스별로 기억), ③ 활성 탭의 나머지 pane(레이아웃 순서) 순서로 고른다. 그중 **실제 git
  작업트리인 첫 후보**가 이긴다 — 스냅샷에는 전역으로 포커스된 pane 하나만 표시되므로, 이 순서가 없으면
  포커스를 잃은 워크스페이스가 맨 앞 pane(대개 `$HOME` 셸)로 떨어져 행이 비어 버린다.

## 요구 사항

- herdr ≥ 0.9.0 (Linux / macOS)
- herdr 서버의 `PATH` 에 `bash`, `jq`, `git`, `flock`(util-linux)

## 설치

```sh
herdr plugin install unstable-code/herdr-space-branch
```

개발용으로는 로컬 클론을 `link` 한다 — 작업트리를 그대로 쓰므로 `git pull` 이 곧 업데이트다.

```sh
git clone https://github.com/unstable-code/herdr-space-branch.git
herdr plugin link ./herdr-space-branch
```

그다음 `~/.config/herdr/config.toml` 에서 내장 칸 대신 토큰을 그리게 한다.

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"], ["$branch", "$git_status"]]
```

적용은 `herdr server reload-config`(또는 설정해 둔 reload 키).

데몬 틱을 기다리기 싫을 때를 위해 수동 갱신 액션을 키에 걸어 둘 수도 있다.

```toml
[[keys.command]]
key = "prefix+shift+b"
type = "plugin_action"
command = "unstable-code.herdr-space-branch.refresh"
description = "refresh space branch"
```

## 설정

선택 사항이며, 이 플러그인의 설정 디렉터리
(`herdr plugin config-dir unstable-code.herdr-space-branch`) 안 `config.toml` 에 둔다.

```toml
strict = false       # 아래 표 참조
interval = 2         # 데몬 틱(초)
refresh_every = 15   # 몇 틱마다 ahead/behind 재계산
```

`strict` 는 지금 보고 있는 pane 이 git 작업트리가 **아닐 때**(예: `$HOME` 에 있는 셸) 어떻게 할지를 정한다.

| | `strict = false` (기본) | `strict = true` |
|---|---|---|
| 보고 있는 pane 이 저장소 | 그 저장소 | 그 저장소 |
| 보고 있는 pane 은 아니지만 같은 탭에 저장소 pane 이 있음 | 그 저장소 | 행을 비움 |
| 탭의 어느 pane 도 저장소가 아님 | 행을 비움 | 행을 비움 |

기본값은 잠깐 셸로 나가도 행이 쓸모를 유지하는 쪽이고, `strict` 는 지금 있는 pane 에 대해 정확한 쪽이다.

## 검증

격리된 herdr 0.9.0 서버에서 저장소 둘을 한 워크스페이스에 담아 확인했다 — 첫 탭은 `main` 인 `repo-a`,
둘째 탭은 upstream 보다 2 커밋 앞선 `develop` 의 `repo-b`.

| 포커스된 pane | 워크스페이스 토큰 |
|---|---|
| `repo-b` | `branch=develop`, `git_status=↑2` |
| `repo-a` | `branch=main` (git_status 지워짐) |

포커스된 pane 안에서 `git switch -c feature-x` 를 실행한 경우(herdr 이벤트가 없는 경로)는 데몬이 6초 안에,
워크스페이스의 활성 탭을 다른 저장소로 바꾼 경우는 5초 안에 반영했다. `bin/watch --spawn` 을 동시에 5번 불러도
데몬은 정확히 하나였고, 서버가 멈춘 뒤 스스로 종료했다. 훅 실행은 모두 종료 코드 0, 각 50~110ms.

서버를 강제 종료했다 다시 띄우면 워크스페이스 토큰이 비는데, 데몬이 포커스 이벤트 없이 4초 안에
`branch=master` 를 되돌렸다. 같은 재시작을 이전 버전으로 해 보면 행이 계속 비어 있었다.

## 한계

- 워크스페이스 **이름(label)** 은 여전히 첫 탭 기준이다. 브랜치 칸만 포커스를 따라간다.
- pane 안에서 바꾼 브랜치는 즉시가 아니라 다음 데몬 틱(기본 2초)에 반영된다.
- 포커스 이벤트마다 셸 하나와 `herdr pane get` 한 번, `git` 두어 번이 돈다. 데몬은 2초마다 워크스페이스당
  `stat` 한 번을 더한다.
- `git_status` 는 내장 칸과 마찬가지로 ahead/behind 만 본다. 커밋하지 않은 변경은 반영하지 않는다.

## License

[MIT](LICENSE)
