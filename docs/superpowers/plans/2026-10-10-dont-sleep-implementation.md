# Don’t Sleep Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Собрать локальную рабочую .app Don’t Sleep с выбранным дизайном Б, таймерами и проверяемым восстановлением сна.

**Architecture:** Непривилегированный интерфейс, системный контроллер с единственным исполнителем операций питания и независимый watchdog. Логика сессии отделена от IOKit, XPC, времени и файловой системы; все сценарии отказов сначала проверяются без изменения питания Mac.

**Tech Stack:** Swift, SwiftUI/AppKit, IOKit, Foundation, XPC, launchd/SMAppService; Swift Package для тестируемого ядра и сборки, нативный .app bundle.

**Spec:** [Спецификация v1.3](../specs/2026-10-10-dont-sleep-design.md). [Дизайн Б](../../design/references/menu-layout-concept.png).

## Global Constraints

- Native macOS ARM64, целевое устройство M4 Pro/macOS 26.7.1. Нет Electron/WebView, Dock, автозапуска UI и автоматического возобновления режима.
- «Без таймера», «На 5 минут», «На 15 минут», «На 30 минут», «На 1 час», «На 4 часа», «На 8 часов». Повторный выбор сбрасывает таймер на полную длительность.
- На аккумуляторе включение только строго >20%; при ≤20% восстановление и блокировка, AC разрешает включение независимо от процента. Возврат питания не включает режим.
- Открытие крышки и смена питания сохраняют сессию, кроме условий защиты. Экран не блокируем и не удерживаем включённым.
- Заряд всегда слева под статусом; активный таймер справа. Выход: «Выключить и выйти» или «Выйти»; Command-Q использует тот же подтверждённый путь.
- Пульс UI каждые 5 секунд только в активной сессии, lease максимум 30 секунд; нормальная остановка не ждёт lease. Недостоверное питание блокирует активацию.
- Журнал до мутации; восстановление исходных значений, проверка результата чтением; не сбрасывать чужие настройки.
- Один исполнитель; невозможно повторное включение старым поколением после восстановления. Все внешние команды ограничены временем и контролем завершения.
- GUI не root. Нет хранения пароля, отключения SIP, произвольного shell через XPC или fail-open аутентификации.
- Ошибка восстановления не выдаётся за OFF и не разрешает обычный выход. Службы восстанавливают собственную операцию после reboot без UI.
- Собственный CPU: активный ≤0,5% одного ядра в среднем за 15 минут; выключенный ≤0,1%. Целевая дополнительная мощность ≤max(0,2 Вт; 5% контроля), доказать измерением.
- Публичная документация означает готовые файлы в проекте; публикация в интернете, push и отправка сообщений не входят в задачу.
- Не выдавать демонстрационный backend за реальную работу сна. Сборка с неподтверждённой безопасностью не объявляется готовой к работе без наблюдения.

## Review Focus

1. Быстрые повторные start/stop/quit и старые ответы XPC: завершённая сессия не оживает (Task 2/4).
2. Crash между fsync журнала, мутацией и ответом: сохраняется пригодный исходный снимок (Task 3).
3. Зависший дочерний pmset и повторное использование PID: watchdog не создаёт двух исполнителей и не убивает чужой процесс (Task 4).
4. Повторная установка/обновление подписанного клиента: старый клиент не получает новые права, unfinished journal не уничтожается (Task 1/6).
5. Locked UI, смена часов и App Nap: нельзя ни бесконечно продлевать замёрзший интерфейс, ни зависеть от календарных часов (Task 2/5/7).

## Организация и полномочия

Пользователь поручил оркестрацию, выбор моделей и непрерывную работу до показываемой версии. План не требует дополнительного промежуточного утверждения: последнее прямое поручение пользователя имеет приоритет над стандартной остановкой навыка writing-plans.

Оркестратор владеет контрактами, Package.swift, интеграцией и конечным результатом. Исполнитель получает точный scope, пути, контракт, критерии проверки и отдельный отчёт. Ревьюер не автор своего изменения. Общие файлы редактируются одним владельцем; независимая работа возможна только после фиксации интерфейсов.

- Системная архитектура и сложная защита: gpt-6-astra/high.
- Core, UI, интеграционные изменения: gpt-6.1-sol/high.
- Независимое security и финальное ревью: gpt-6-astra/high или xhigh по риску.
- Обычное task-review и документация из фактов: gpt-6.1-sol/medium.
- Механические узкие правки допускают более дешёвую доступную модель. Не запускать мощные модели без конкретной задачи.
- Передать agent briefs без полной истории, с явными моделями; не раздавать вложенную оркестрацию исполнителям.
- Использовать subagent-driven-development, TDD для логики и интеграций; для картинок, конфигурации и документации — адресная проверка.
- После каждой задачи: проверка требований и качества; после привилегированных изменений security-review. Не повторять одни и те же тесты без изменений/новой гипотезы.
- Локальный Git отсутствует. При начале реализации создать локальную историю и рабочую ветку, без remote/push. Для этой новой кодовой базы работать в текущем каталоге с явным владением файлами; отдельный checkout ничего существующего не изолирует. Результаты вести в docs/implementation/progress.md.
- Команды установки/системные запросы прав не смешивать с тестами ядра. Не запускать новый реальный запрет сна автоматически: перед аппаратным испытанием дать конкретный сценарий и учесть существующую авторизацию пользователя; действия, требующие его присутствия, оставить последним шагом после готовой сборки.

## Структура

- Package.swift — библиотеки DontSleepCore, DontSleepPlatform, executable DontSleepApp, Controller, Watchdog.
- Sources/DontSleepCore/ — Mode, PowerSnapshot, SessionState, SessionEngine, Clock, ServiceMessages.
- Sources/DontSleepPlatform/ — NativePowerMonitor, SleepBackend, RecoveryJournal, ServiceConnection, TrustPolicy, HelperRegistration.
- Sources/DontSleepController/ — main.swift, ControllerService.
- Sources/DontSleepWatchdog/ — main.swift, RecoverySupervisor.
- Sources/DontSleepApp/ — AppMain, AppModel, MenuContent, EyeIcon, Notifications, QuitCoordinator.
- Tests/DontSleepCoreTests/, Tests/DontSleepPlatformTests/ — deterministic tests and temporary-root filesystem/process fixtures.
- Resources/ — Info.plist, launchd plists, assets; scripts/build-app.sh — local reproducible build/sign/bundle, no power mutation.
- docs/implementation/ — feasibility, trust decision, progress, test reports.
- README.md, docs/user-guide.md, docs/troubleshooting.md — пользовательские инструкции.
- dist/Don’t Sleep.app — конечный локальный артефакт, не в Git.

Имена/границы могут уточняться по проверенному SDK в Task 1; изменение контракта фиксируется оркестратором до передачи зависимой задачи.

## Task 1 — доказать локальную установку и доверие

**Owner:** platform engineer; **review:** security. **Depends:** none.
**Files:** docs/implementation/platform-feasibility.md, Package.swift, Resources/Info.plist, Resources/launchd/*.plist, scripts/build-app.sh; безопасный probe в tools/ServiceProbe/.
**Interfaces:** результат — документированный TrustConfiguration (способ подписи, требование доверия, идентификаторы служб, install/status/uninstall). Произвольная root-команда не является интерфейсом.

- [ ] Проверить SDK, доступную подпись и SMAppService, не меняя сон. Зафиксировать реальный результат, не предполагать наличие Developer ID.
- [ ] Создать минимальный probe status-only: допустимый клиент получает protocolVersion=1; другой подписанный/unsigned клиент и неверная версия отвергаются.
- [ ] Построить probe и выполнить негативные проверки аутентификации; отказ установки не должен выдаваться за успех.
- [ ] Зафиксировать точный путь установки/удаления и обновления доверия. Если SMAppService недоступен для доступной подписи, выбрать и независимо проверить безопасный локальный install с закреплённой идентичностью; не ослаблять клиентскую проверку.
- [ ] Собрать build harness, сохраняющий root-службы и GUI раздельными executable. Команда scripts/build-app.sh должна создавать .app без регистрации служб/активации.
- [ ] Review gate: ни код режима, ни GUI не получают право включения до подтверждения доверия; код и сборку можно развивать с заблокированной активацией.
- [ ] Записать результаты и локальный commit.

## Task 2 — ядро состояний и времени

**Owner:** core engineer. **Depends:** базовый Package.swift Task 1.
**Files:** Sources/DontSleepCore/{Mode,PowerSnapshot,SessionState,SessionEngine,Clock,ServiceMessages}.swift; Tests/DontSleepCoreTests/SessionEngineTests.swift.
**Interfaces:** Mode: Codable/CaseIterable с permanent и minutes(Int) из allowlist; PowerSnapshot(source: ac/battery/unknown, percent: Int?, sampledAt: UInt64); SessionState(off/enabling/active/restoring/failed/setupRequired); SessionEngine.handle(Event, now: UInt64) -> [Effect]. Event покрывает enable(mode), disable, quit, power(sample), lease, deadline, applyResult, restoreResult, bootRecovery; эффекты не вызывают ОС. Монотонное время в целых секундах; sessionID UUID + generation UInt64.

- [ ] Написать failing tests: battery 19/20 запрещает, 21 разрешает; AC20 разрешает; unknown запрещает; питание восстановилось — эффект enable отсутствует.
- [ ] Запустить swift test --filter SessionEngineTests; подтвердить красный тест нужного поведения, затем реализовать reducer.
- [ ] Добавить тесты длительностей 300/900/1800/3600/14400/28800, permanent без deadline; повторный выбор в t=10 для 300s даёт deadline=310, не старые 300.
- [ ] Добавить lease expiry в t=30, обновление только правильной сессии, clock rollback не влияет; repeatQuit даёт одно намерение, restoreFailure не off и не terminate, restoreSuccess после quit даёт terminate.
- [ ] swift test: все core тесты проходят; reviewer проверяет границы и отсутствие OS side effects; commit.

## Task 3 — снимок, журнал и ограниченная операция сна

**Owner:** platform engineer. **Depends:** Task 1/2.
**Files:** Sources/DontSleepPlatform/{SleepBackend,RecoveryJournal,BoundedProcess,NativePowerMonitor}.swift; Tests/DontSleepPlatformTests/{JournalTests,BackendTests,PowerTests}.swift.
**Interfaces:** SleepBackend.read() throws -> SleepSnapshot; applyDisabled() throws; restore(SleepSnapshot) throws; verify(SleepSnapshot) throws -> Bool. RecoveryJournal.load() throws -> RecoveryRecord?; persist(RecoveryRecord) throws; markRestored(sessionID: UUID) throws. NativePowerMonitor выдаёт PowerSnapshot в Event, не меняет настройки.

- [ ] Написать failing tests в временном каталоге: interrupted write сохраняет либо старую, либо новую полную запись; symlink/wrong owner/corrupt schema отвергаются; no record не вызывает restore.
- [ ] swift test --filter JournalTests; реализовать atomic durable journal, owner/mode проверку, snapshot до side effect.
- [ ] Тест backend на fake subprocess: exit0+неверный readback — failure; timeout требует reap перед следующей записью; чужое disablesleep=true до старта — conflict.
- [ ] Реализовать фиксированные системные команды без shell, ограниченный child lifecycle и реальное чтение действующего/сохранённого состояния. Зафиксировать поддержку текущей ОС; не предполагать формат неизвестного значения.
- [ ] Тестировать парсер/IOKit адаптер на AC20,battery20,battery21, missing/invalid data. Не использовать настоящий pmset-write в unit suite.
- [ ] swift test; security-review журнал/child/path safety; commit.

## Task 4 — контроллер, watchdog и IPC

**Owner:** system engineer. **Depends:** 1–3.
**Files:** Sources/DontSleepController/{main,ControllerService}.swift; Sources/DontSleepWatchdog/{main,RecoverySupervisor}.swift; Sources/DontSleepPlatform/{ServiceConnection,TrustPolicy}.swift; Tests/DontSleepPlatformTests/RecoveryIntegrationTests.swift.
**Interfaces:** версионированные Codable request/reply из Core, XPC transport ограничивает размер и класс Data. Команды status/start(mode,requestID)/heartbeat(sessionID,generation)/stop(requestID). Служба выдаёт SessionState, PowerSnapshot, deadline, issue и result; запрещён произвольный command/path/originalValue.

- [ ] До реализации письменно определить единственного writer и takeover. Watchdog не выполняет pmset параллельно с прежним controller/child; проверка старого PID включает принадлежность и завершение. Если это невозможно доказать, пересмотреть владение actuator до реальных изменений.
- [ ] Написать интеграционные failing tests на fake backend и настоящих вспомогательных процессах без root: crash на каждом этапе, controller hang, watchdog failure, stalled child, stale generation, duplicate start/quit.
- [ ] Реализовать service state machine с последовательными эффектами; journal восстанавливается до новых активаций. UI freeze перестаёт получать lease; lost guard инициирует restore.
- [ ] Запустить swift test --filter RecoveryIntegrationTests. В каждом failure case либо verified restored, либо явная ошибка с запрещённым start; никогда ложный OFF.
- [ ] Аутентифицировать обе стороны, отклонять oversized/malformed/replayed requests и недоверенный клиент. Доказать тестами.
- [ ] Security-review до разрешения реального backend; commit.

## Task 5 — приложение и выбранный дизайн Б

**Owner:** UI engineer. **Depends:** публичные контракты Task 2; fake preview можно параллельно 3/4.
**Files:** Sources/DontSleepApp/{AppMain,AppModel,MenuContent,EyeIcon,Notifications,QuitCoordinator}.swift; Tests/DontSleepCoreTests/PresentationTests.swift; Resources/Assets/.
**Interfaces:** AppModel принимает ServiceClient (status/start/heartbeat/stop), отдаёт наблюдаемое presentation state. QuitCoordinator.requestQuit() сохраняет намерение; terminate только по verifiedOff. Preview transport явно только для design snapshots, не default fallback.

- [ ] Написать failing presentation tests: exit label ON/OFF, все7режимов, chargeleft/timeonlyactive, unknown battery dash, error вместо OFF, lowbattery/error icons.
- [ ] Реализовать нативный MenuBarExtra/AppKit popover по Б: SF13/14, семантические цвета, режимы30pt, заряд+таймер12pt. Все команды доступны с клавиатуры.
- [ ] Реализовать template/vector eye + bolt, lowbattery emptyeye+amberbadge, errorbadge; .icns локально из векторного исходника, не из обрезанного генеративного скриншота.
- [ ] Подключить lifecycle/Command-Q к QuitCoordinator, включая termination delegate. Пульс зависит от main-thread responsiveness, не работает после OFF. Нет ежесекундного redraw закрытого меню.
- [ ] Показать реальные native snapshots ON/OFF/low/error, light/dark; long8:00:00+100%, крупный текст, VoiceOver labels, focus, Reduce Transparency. Команды render/preview не меняют питание.
- [ ] swift test; native build + targeted UI checks; независимый spec/quality review; commit.

## Task 6 — установка и пользовательская сборка

**Owner:** integration engineer (оркестратор либо отдельный агент). **Depends:** 1,4,5.
**Files:** Sources/DontSleepPlatform/HelperRegistration.swift, scripts/{build-app,verify-bundle}.sh, Resources/*; Tests/DontSleepPlatformTests/RegistrationTests.swift.
**Interfaces:** HelperRegistration.status() -> ready/approvalRequired/missing/error; register() async throws; unregisterAfterVerifiedRestore() async throws.

- [ ] Failing tests отказа/недостающей службы/несовпадения версии; UI не активирует режим и показывает «Настроить».
- [ ] Реализовать выбранный в Task1 install без пароля в приложении. Повторная установка не удаляет unfinished journal, unregister идёт только после verify restore.
- [ ] scripts/build-app.sh; scripts/verify-bundle.sh dist/Don’t\ Sleep.app. Проверить executable/launchd paths, подписи, разрешения, отсутствие секретов/демо-backend по умолчанию.
- [ ] Проверить запуск без Dock/автостартаUI, единичный экземпляр, корректный setup state. Службы не регистрировать скрытно build-скриптом.
- [ ] Review и commit; сборка готова к системному подтверждению установки.

## Task 7 — приёмка, измерения, документация и финальное ревью

**Owner:** оркестратор; docs engineer после готовых фактов; отдельный final/security reviewer.
**Files:** README.md, docs/{user-guide,troubleshooting}.md, docs/implementation/{acceptance,energy-report}.md; scripts/test-safe.sh; dist/Don’t Sleep.app.
**Interfaces:** финальный отчёт разделяет automated pass, hardware pass, пользовательские действия и непроверенные сценарии.

- [ ] Выполнить swift test и существующие python3 -m unittest discover -s poc/tests; не дублировать unit прогоны без изменений.
- [ ] Провести read-only/native UI smoke и собрать артефакт .app. Подготовить конкретный план установочного подтверждения/аппаратных проб, без автоматического включения режима.
- [ ] Когда системные права подтверждены, проверить реальные stop/quit, guard failures и boot recovery с готовым восстановлением. Lid5min наAC/наbattery требует физического действия пользователя. Непройденное пометить pending, не выдумывать pass.
- [ ] Измерить CPU15min и сравнительное питание по spec7.4; агент документации не обещает расход батареи до результатов.
- [ ] Написать инструкцию запуска/установки/обновления/удаления, предупреждение про сумку и блокировку, поведение20%, сообщение при отказе админа, диагностику и восстановление. Не публиковать во внешние сервисы.
- [ ] Финальное независимое ревью всей интеграции и привилегированного кода, исправления + адресная повторная проверка. Блокирующие security/recovery findings не допускаются к безнадзорной работе.
- [ ] Показать пользователю рабочую сборку, её путь, подтверждённые возможности и оставшиеся физические проверки. Если установка/подпись объективно заблокирована, сообщить конкретный blocker, но завершить всё независимое.
