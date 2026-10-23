# Architecture index

A fact index of modules, targets, dependencies, entry points, data flows, storage paths, resources and tool entry points. Contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md); debugging and simulator automation are in [DEBUG.md](DEBUG.md). Paths are relative to the repository root; symbols are named in backticks rather than linked by line.

## 1. Identity

| Item | Value | Declared in |
| --- | --- | --- |
| Bundle id (host app) | `app.songyan.ime` (`SONGYAN_BUNDLE_ID`) | [Config/Identity.xcconfig](Config/Identity.xcconfig); the project uses `$(SONGYAN_BUNDLE_ID)` in [project.pbxproj](Songyan.xcodeproj/project.pbxproj) |
| Bundle id (keyboard extension) | `$(SONGYAN_BUNDLE_ID).keyboard` | [project.pbxproj](Songyan.xcodeproj/project.pbxproj) |
| App Group | `group.app.songyan.shared` (`SONGYAN_APP_GROUP`) | [Config/Identity.xcconfig](Config/Identity.xcconfig); entitlements [HostApp.entitlements](Apps/HostApp/HostApp.entitlements) and [KeyboardExtension.entitlements](Apps/KeyboardExtension/KeyboardExtension.entitlements) use `$(SONGYAN_APP_GROUP)`; both Info.plists carry `SongyanAppGroup`; runtime constants `KeyboardRecipeStore.defaultGroupID` / `declaredGroupID` in [RimePaths.swift](Apps/SharedKeyboard/RimePaths.swift) |
| Development team | `DEVELOPMENT_TEAM` (empty by default) | [Config/Identity.xcconfig](Config/Identity.xcconfig) |
| Local overrides | optional, git-ignored `Config/Local.xcconfig`, included last by `Identity.xcconfig` | [Config/Identity.xcconfig](Config/Identity.xcconfig) |
| Minimum OS / Swift language mode | iOS 17.0 / Swift 5.0 | [project.pbxproj](Songyan.xcodeproj/project.pbxproj) |
| Version | `MARKETING_VERSION 0.1.0`, `CURRENT_PROJECT_VERSION 1` | [project.pbxproj](Songyan.xcodeproj/project.pbxproj) |
| Extension point | `com.apple.keyboard-service`; `IsASCIICapable=true`, `RequestsOpenAccess=true`, `PrimaryLanguage=zh-Hans` | [Apps/KeyboardExtension/Info.plist](Apps/KeyboardExtension/Info.plist) |
| Extension build settings | `APPLICATION_EXTENSION_API_ONLY=YES`, `GENERATE_INFOPLIST_FILE=NO`, bridging header `DocumentIdentityBridge.h` | [project.pbxproj](Songyan.xcodeproj/project.pbxproj) |

## 2. Targets

| Target | Type | Sources | Package dependencies |
| --- | --- | --- | --- |
| `HostApp` | application | [Apps/HostApp](Apps/HostApp) | KeyboardCore, RimeBridge, PackageManager, LayoutKit, SkinKit, QuickContentKit, CandidateKit, AppearanceKit |
| `KeyboardExtension` | app extension | [Apps/KeyboardExtension](Apps/KeyboardExtension) | the same list without PackageManager |
| Shared sources | compiled into both targets, once each | [Apps/SharedKeyboard](Apps/SharedKeyboard) | membership checked by [test_pbx_object_graph.py](Tests/ProjectStructure/test_pbx_object_graph.py) |
| Scheme | `HostApp` (the only shared scheme) | [HostApp.xcscheme](Songyan.xcodeproj/xcshareddata/xcschemes/HostApp.xcscheme) | |

## 3. Modules and dependencies

Each package has its own `Package.swift` under `Packages/<Name>`.

| Module | Depends on |
| --- | --- |
| KeyboardCore, LayoutKit, SkinKit, QuickContentKit | none |
| CandidateKit | KeyboardCore, LayoutKit |
| AppearanceKit | SkinKit, CandidateKit |
| PackageManager | ZIPFoundation, Yams, KeyboardCore |
| RimeBridge | `RimeKit` (binaryTarget, `Vendored/RimeKit.xcframework`), `RimeLeversSupport` |
| RimeLeversSupport | `RimeKit` |

`RimeLeversSupport` ([sources](Packages/RimeBridge/Sources/RimeLeversSupport)) is a C target inside the RimeBridge package that forwards librime's levers API (`rls_available`, `rls_prepare_installation`, `rls_user_dict_list_*`, `rls_backup_user_dict`, `rls_restore_user_dict`) to Swift. It is compiled with `-fno-modules` against the original public headers, and booleans cross the boundary as explicit `int`. Outside Xcode, [build-learning-support.py](Tools/BuildRimeIOS/scripts/build-learning-support.py) builds its object file and module map from a `--kit-include-dir`.

### Engine artifact

- [RimeKitArtifact.json](Packages/RimeBridge/RimeKitArtifact.json) records the vendored engine: the artifact path, the generator and export scripts, the slices `ios-arm64` and `ios-arm64-simulator` with their archive path and SHA-256, and the files that pin the upstream commits ([VERSIONS.env](Tools/BuildRime/VERSIONS.env) and the plugin `*-VERSIONS.env` files in [Tools/BuildRimeIOS](Tools/BuildRimeIOS)).
- `Packages/*/Vendored/` content is produced by [Tools/BuildRimeIOS](Tools/BuildRimeIOS): [43-build-rimekit.py](Tools/BuildRimeIOS/scripts/43-build-rimekit.py) rebuilds librime and plugins from pinned sources (plugin sources fetched by [09-fetch-plugins.sh](Tools/BuildRimeIOS/scripts/09-fetch-plugins.sh)) with `-ffile-prefix-map`, and [export-rimekit.py](Tools/BuildRimeIOS/scripts/export-rimekit.py) checks the archives (required engine entry points, no absolute build paths), copies them into `Vendored/` and rewrites the manifest. `export-rimekit.py --check` re-verifies the installed copy and runs in `make release`.
- Components initialised by the bridge: `default`, `levers`, `lua`, `octagram`, `t9_original`, `predict`. Deployment preflight asks the live engine (`rb_component_available`); a scheme that needs a missing component is skipped with a warning.
- Native nine-key processor: [rime_t9_processor.cc](Tools/BuildRimeIOS/src/rime_t9_processor.cc) and [rime_t9_keys.h](Tools/BuildRimeIOS/src/rime_t9_keys.h). Digits 2-9 (including the physical keypad) are handed to librime's `Speller` with the scheme's own digit prism; modifier keys, ASCII mode and other keys pass through. The built-in 9-key companions (`keyboard_*_9.schema.yaml` in [Resources/BuiltinPackages/Basic](Resources/BuiltinPackages/Basic)) do not list the processor.
- Prediction after commit uses upstream [librime-predict](https://github.com/rime/librime-predict) (pinned in [PREDICT-VERSIONS.env](Tools/BuildRimeIOS/PREDICT-VERSIONS.env)). The app neither bundles nor downloads a predict database; the user imports one (header `Rime::Predict/` is validated).
- A librime patch ([librime-tsv-write-failures.patch](Tools/BuildRimeIOS/patches/librime-tsv-write-failures.patch)) makes the user-dictionary TSV writer report stream errors.

## 4. Module entry points

| Module | Main types |
| --- | --- |
| KeyboardCore: engine boundary | `EngineBackend`, `EngineProvider`, `DemoEngine` (Engine/); `SentenceSpelling`; `CandidateReadingFilter.swift` (`CandidateReadingBatch`, `ReadingInputCoverage`); [SpellingRailChoices.swift](Packages/KeyboardCore/Sources/KeyboardCore/Engine/SpellingRailChoices.swift) (live capability/revision gate for selectable spellings) |
| KeyboardCore: session and layout | `InputSession` (Session/), `KeyboardLayout`, `KeyAction` (Layout/) |
| KeyboardCore: publication | `PublishedKeyboard`, `PublishedKeyboardRoster`, `KeyboardResourceSet`, `KeyboardRouteIdentity`, `UserKeyboardPublicationTransaction` (Engine/) |
| KeyboardCore: support | `UserKeyboard`, `GrammarModelPath`, `ProxyDocumentContext`, `EnglishNextWord`, `T9PunctuationCycle`, `LearningTransferStore`, `LearningBackupArchive` (Support/); `QuickInsertCore` (QuickInsert/) |
| LayoutKit | `LayoutDefinition`, `LayoutRegistry`/`LayoutStore`, `BuiltinLayouts`, `CompactSpellingLayout`, `LetterGroupLayout`, `MergedKeypadGeometry`, `LetterSwipeTracker`, `AlternateKeyPolicy`, `AlternateDragPicker`, `KeyboardControlPolicy`, `PhoneKeypadRailPolicy`, `T9QuickSymbolStore`, `LayoutResourceBudget`; [ShuangpinHintPreset.swift](Packages/LayoutKit/Sources/LayoutKit/ShuangpinHintPreset.swift), [ShuangpinHintStore.swift](Packages/LayoutKit/Sources/LayoutKit/ShuangpinHintStore.swift), [ShuangpinHintOverlay.swift](Packages/LayoutKit/Sources/LayoutKit/ShuangpinHintOverlay.swift) (explicit display presets, one hint per letter of each letter key) |
| CandidateKit | `CandidateBrowser`, `CandidateBarDefinition`, `CandidateAreaRendering`, `CandidatePresentation`, `CandidateCollapsedFlow`, `KeyboardPanelGeometry`, `KeyboardPanelSizing`, `KeyboardHeightPreset` (48/54/60 pt portrait, 44 pt compact), [OneHandLayoutPolicy.swift](Packages/CandidateKit/Sources/CandidateKit/OneHandLayoutPolicy.swift) (`KeyboardOneHandMode`, finite real-width plans for iPhone portrait; full width elsewhere) |
| AppearanceKit / SkinKit | `AppearanceStore`, `AppearanceDocument` / `SkinDefinition`, `KeyboardAppearancePolicy` |
| QuickContentKit | `SymbolCatalog`, `SymbolCatalogStore`, `RecentSymbolStore`, `QuickContentFileReader` (bounded same-descriptor reads); [LocalQuickContentStore.swift](Packages/QuickContentKit/Sources/QuickContentKit/LocalQuickContentStore.swift) (`CommonPhrase`, opt-in explicit-paste history, bounded local storage and phrase-only transfers) |
| PackageManager | `RecipePackageManager`, `SchemeImport`, `DictionaryImport`, `SchemePackageDeletion`, `DeclarativeRecipe`, `SchemeReimport`, `GrammarModel`, `GrammarModelManagement`, [FuzzyPinyin.swift](Packages/PackageManager/Sources/PackageManager/FuzzyPinyin.swift) (bounded per-method native fuzz patches), `TypoCorrection`, `Prediction`, `LuaComponents`, `LuaSandbox`, `BoundedYAML`, `BoundedLocalFile` |
| RimeBridge | `RimeEngine`, `RimeKey`, `RimeModels`, `RimeLearningBackup` |

Built-in keyboard shells (nine-key, the merged 14-key and 18-key pad, 26-key) live in [KeyboardPanelView.swift](Apps/SharedKeyboard/KeyboardPanelView.swift) (the panel's composition) and its `KeyboardPanelView+*.swift` extensions: key rows ([+KeyRows](Apps/SharedKeyboard/KeyboardPanelView+KeyRows.swift)), layout definition resolution ([+LayoutDefinitions](Apps/SharedKeyboard/KeyboardPanelView+LayoutDefinitions.swift)), definition-driven keys ([+DefinitionKeys](Apps/SharedKeyboard/KeyboardPanelView+DefinitionKeys.swift)), nine-key rails and symbol pages ([+NineKey](Apps/SharedKeyboard/KeyboardPanelView+NineKey.swift)), control row ([+ControlRow](Apps/SharedKeyboard/KeyboardPanelView+ControlRow.swift)), candidate bar ([+CandidateArea](Apps/SharedKeyboard/KeyboardPanelView+CandidateArea.swift)) and the settings panel ([+Utilities](Apps/SharedKeyboard/KeyboardPanelView+Utilities.swift)). Key views are [WeightedKeyRow.swift](Apps/SharedKeyboard/WeightedKeyRow.swift), [AlternateCharacterKey.swift](Apps/SharedKeyboard/AlternateCharacterKey.swift) (alternates popup in [AlternateCharacterKey+Popup.swift](Apps/SharedKeyboard/AlternateCharacterKey+Popup.swift)), [KeyboardControlKeys.swift](Apps/SharedKeyboard/KeyboardControlKeys.swift), [KeyCalloutView.swift](Apps/SharedKeyboard/KeyCalloutView.swift) and [StableKeyboardControls.swift](Apps/SharedKeyboard/StableKeyboardControls.swift); their control layout is driven by `KeyboardControlPolicy` and `PhoneKeypadRailPolicy`. Long-press alternates come from `AlternateKeyPolicy` (nine-key digit keys and the first key use their layout-declared alternates instead); symbol pages use `SymbolPageTable` ([SymbolPageTable.swift](Apps/SharedKeyboard/SymbolPageTable.swift)). The nine-key bottom row is 123 | 中/英 | 空格 | 符号 (`KeyboardControlPolicy.isBundledPhonePad`), with a wide space bar and long press on 符号 typing 0; its 符号 key, and #+= on the 123 page of the 14-, 18- and 26-key layouts, open one categorised symbol page: 常用, 最近, 中文, 英文 and 括号, then the symbol library's sets, read through `SymbolLibraryModel`. It always opens on 常用 and goes back to the typing page after one symbol unless 锁定 is on (session-only, never stored). The nine-key first-key punctuation cycle is `T9PunctuationCycle` (repeat taps within 0.8 s replace the previous symbol while the text anchor and commit generation match).

## 5. Host app entry points

| Entry | Symbols and files |
| --- | --- |
| App and root | `HostApp` ([HostApp.swift](Apps/HostApp/HostApp.swift)), `HostRootView` ([HostLaunchSupport.swift](Apps/HostApp/HostLaunchSupport.swift)), `MainTabView` ([MainTabView.swift](Apps/HostApp/MainTabView.swift)) |
| Schemes and sources | `KeyboardSelectionCenter` ([KeyboardSelectionCenter.swift](Apps/HostApp/KeyboardSelectionCenter.swift); what the keyboard uses, switch back to built-in), `InputSchemeListView` ([InputSchemeListView.swift](Apps/HostApp/InputSchemeListView.swift)), [InstalledSchemeDetailView.swift](Apps/HostApp/InstalledSchemeDetailView.swift) (custom pinyin details; installed schemes, the built-in one included, use [SchemePackageDetailView.swift](Apps/HostApp/SchemePackageDetailView.swift)), `DictionaryDeployVerifier` / `EngineSchemaSelection` ([EngineDeployVerification.swift](Apps/HostApp/EngineDeployVerification.swift)) |
| Host storage and log | `HostStorePaths`, `HostLog` ([HostStorage.swift](Apps/HostApp/HostStorage.swift)); private stores under Application Support, diagnostic log `Documents/host.log` |
| Import and deletion | `DictionaryImportCenter` ([DictionaryImportCenter.swift](Apps/HostApp/DictionaryImportCenter.swift)), `SchemeImportCenter` ([SchemeImportCenter.swift](Apps/HostApp/SchemeImportCenter.swift); extensions [SchemeImportCenter+ExternalResources.swift](Apps/HostApp/SchemeImportCenter+ExternalResources.swift), [SchemeImportCenter+Recipes.swift](Apps/HostApp/SchemeImportCenter+Recipes.swift), [SchemeImportCenter+Sources.swift](Apps/HostApp/SchemeImportCenter+Sources.swift), [SchemeImportCenter+Grammar.swift](Apps/HostApp/SchemeImportCenter+Grammar.swift), [SchemeImportCenter+Keyboards.swift](Apps/HostApp/SchemeImportCenter+Keyboards.swift), [SchemeImportCenter+Install.swift](Apps/HostApp/SchemeImportCenter+Install.swift), [SchemeImportCenter+Update.swift](Apps/HostApp/SchemeImportCenter+Update.swift)), `SchemeKeyboardPublicationTransaction` ([SchemeKeyboardPublicationTransaction.swift](Apps/HostApp/SchemeKeyboardPublicationTransaction.swift)); [DictionaryImportView.swift](Apps/HostApp/DictionaryImportView.swift), [SchemePackageImportView.swift](Apps/HostApp/SchemePackageImportView.swift) and [SchemePackageImportView+Configuration.swift](Apps/HostApp/SchemePackageImportView+Configuration.swift), [RimeSourceInstallView.swift](Apps/HostApp/RimeSourceInstallView.swift), [SchemeURLImportView.swift](Apps/HostApp/SchemeURLImportView.swift), [SchemeURLDownloadService.swift](Apps/HostApp/SchemeURLDownloadService.swift); [SchemePackageDeletionCenter.swift](Apps/HostApp/SchemePackageDeletionCenter.swift) |
| User keyboards (我的键盘) | `UserKeyboardCenter` ([UserKeyboardCenter.swift](Apps/HostApp/UserKeyboardCenter.swift)), [UserKeyboardManagementView.swift](Apps/HostApp/UserKeyboardManagementView.swift); the only place to add, remove and switch input method × layout pairs: Save publishes the edited list, Use publishes it with that pair selected (`SchemeImportCenter.performReplaceKeyboards(selecting:)`). Scheme detail pages list their input methods read-only and link here |
| Appearance, layouts, candidate bar | `AppearanceManager`, `SkinManager`, `LayoutManager` and their management/editor views |
| Content | [T9QuickSymbolManagementView.swift](Apps/HostApp/T9QuickSymbolManagementView.swift), [SymbolCatalogManagementView.swift](Apps/HostApp/SymbolCatalogManagementView.swift) (`SymbolCatalogManagementView`, `QuickContentManagementView`; browse/search, common phrases and clipboard controls) |
| Shuangpin hints | [ShuangpinHintManagementView.swift](Apps/HostApp/ShuangpinHintManagementView.swift), [ShuangpinHintManager.swift](Apps/HostApp/ShuangpinHintManager.swift); Settings > 输入选项 > 双拼提示; file/HTTPS import, DIY edit, export, explicit enable and selected preset |
| Fuzzy pinyin | [FuzzyPinyinSettingsView.swift](Apps/HostApp/FuzzyPinyinSettingsView.swift), [FuzzyPinyinCenter.swift](Apps/HostApp/FuzzyPinyinCenter.swift); Settings > 输入选项 > 模糊音; per-source and per-method drafts insert native `fuzz` rules at the start of `speller/algebra` (`@before` patches; old end-of-list blocks are rewritten on the next save) and are checked against the live engine |
| Input options | [InputOptionsView.swift](Apps/HostApp/InputOptionsView.swift); `TypoCorrectionCenter`, `PredictionCenter`, `LuaComponentsCenter` ([AdvancedSettingsView.swift](Apps/HostApp/AdvancedSettingsView.swift) hosts Lua components) |
| Learning backup | `LearningBackupView` ([LearningBackupView.swift](Apps/HostApp/LearningBackupView.swift)), `LearningBackupModel` ([LearningBackupModel.swift](Apps/HostApp/LearningBackupModel.swift)); the host only submits requests and reads receipts, source identity comes from the structured publication record (`activation.rosterKey`) |
| Engine coordination | `EngineOwnershipCoordinator` ([EngineOwnershipCoordinator.swift](Apps/SharedKeyboard/EngineOwnershipCoordinator.swift)), one per process in the host and the extension |
| Try-out and diagnostics | [TryInputView.swift](Apps/HostApp/TryInputView.swift), [EngineStatusView.swift](Apps/HostApp/EngineStatusView.swift), [ResourceCheckView.swift](Apps/HostApp/ResourceCheckView.swift) |

## 6. Keyboard extension entry points

| Entry | Symbols and files |
| --- | --- |
| Principal class | `KeyboardViewController` ([KeyboardViewController.swift](Apps/KeyboardExtension/KeyboardViewController.swift); proxy document and marked text in [+HostDocument](Apps/KeyboardExtension/KeyboardViewController+HostDocument.swift), route and layout reads in [+Route](Apps/KeyboardExtension/KeyboardViewController+Route.swift), shell geometry in [+Presentation](Apps/KeyboardExtension/KeyboardViewController+Presentation.swift), learning-data poll in [+LearningTransfer](Apps/KeyboardExtension/KeyboardViewController+LearningTransfer.swift), Debug timing probe in [+TimingProbe](Apps/KeyboardExtension/KeyboardViewController+TimingProbe.swift)): `loadView`, `viewDidLoad`, `viewWillAppear`, `viewDidAppear`, `viewWillDisappear`, `textWillChange`, `textDidChange`, `selectionDidChange`, `handleInputModeList` / `advanceToNextInputMode()` |
| Panel hosting | `ExtensionKeyboardPanel` ([ExtensionKeyboardPanel.swift](Apps/KeyboardExtension/ExtensionKeyboardPanel.swift)), `KeyboardPanelHost` ([KeyboardPanelHost.swift](Apps/SharedKeyboard/KeyboardPanelHost.swift)), `KeyboardPanelView`; `HostAppLink` ([HostAppLink.swift](Apps/SharedKeyboard/HostAppLink.swift)) is the only way the keyboard can reach the host app (its settings panel's jump), because an extension has no application object |
| Session and controller | `KeyboardPadSession` ([KeyboardPadSession.swift](Apps/SharedKeyboard/KeyboardPadSession.swift)), `KeyboardController` ([KeyboardController.swift](Apps/SharedKeyboard/KeyboardController.swift) and its `KeyboardController+*.swift` extensions: readings, ambiguity, English suggestions, marked composition, configuration, host traits, direct input, candidates), `RimeBackend` ([RimeBackend.swift](Apps/SharedKeyboard/RimeBackend.swift)) |
| Document identity | [DocumentIdentityBridge.h](Apps/KeyboardExtension/DocumentIdentityBridge.h) |
| Privacy manifests | [Apps/HostApp/PrivacyInfo.xcprivacy](Apps/HostApp/PrivacyInfo.xcprivacy), [Apps/KeyboardExtension/PrivacyInfo.xcprivacy](Apps/KeyboardExtension/PrivacyInfo.xcprivacy); each target uses only its own ([test_privacy_manifest_target_membership.py](Tests/ProjectStructure/test_privacy_manifest_target_membership.py)) |

## 7. Data flows

### Engine and concurrency

- The Rime engine is a process-wide singleton. Creation, start and teardown go through `EngineOwnershipCoordinator` and `EngineOpQueue` ([EngineOpQueue.swift](Apps/SharedKeyboard/EngineOpQueue.swift)), both in [Apps/SharedKeyboard](Apps/SharedKeyboard); engine operations run on that serial queue. Host and extension are separate processes with separate engine instances.
- Reads of `active.json`, layouts and appearance go through `KeyboardResourceReadQueue` ([KeyboardResourceReadQueue.swift](Apps/SharedKeyboard/KeyboardResourceReadQueue.swift)); the main thread does not read disk synchronously. Imports use bounded same-descriptor reads that reject FIFOs and symlinks (`BoundedLocalFile`, `QuickContentFileReader`, `LayoutResourceBudget`).
- When a capability cannot be proven, the code fails closed and falls back to native Rime behavior.
- Candidate ranking and segmentation belong to the engine. The front end does not re-rank.
- The nine-key preedit shows letters for every key press (`ni'hao'y'y`) and is display-only; the committed text always comes from the engine (`SentenceSpelling`).

### Flow table

| Flow | Chain |
| --- | --- |
| Extension start | `viewDidLoad` -> `KeyboardPadSession.start()` -> `EngineOwnershipCoordinator.claim`; the route is resolved in `viewWillAppear` from `active.json`, which is readable without full access; `KeyboardPanelHostLifetime` guards hand-over between controllers |
| Key press | `KeyboardPanelView` -> `KeyboardController.handle(_:)` -> `InputSession.tap(_:)` -> `EngineBackend.processKey`; later code keys of a composition decode on `EngineOpQueue` (`InputSession.codeKeyQueue`) |
| Engine chain | `RimeBackend` -> `RimeEngine` -> `RimeKit.xcframework`. A failed snapshot read throws, quarantines the session and keeps the last trusted snapshot without its commit; cancellation clears the pending commit before the session is released |
| Candidate selection | `KeyboardController.selectCandidate(_:)` -> `InputSession.selectCandidate(_:)` -> `RimeBackend.selectCandidate` |
| Commit | `KeyboardController.onDispatchCommit` -> `KeyboardPadSession.dispatchCommitToHost` -> `KeyboardViewController` -> `textDocumentProxy.insertText`; the callback returns `Bool` and the host rejects a commit when it is not ready or the document changed |
| Marked text | `KeyboardViewController.updateMarked` -> `setMarkedText`; short single-line compositions are inline, long or multi-line ones use the in-keyboard display and still commit as one piece |
| Document anchor | `ProxyDocumentContext`: 32 UTF-16 units each side of the cursor (whole characters) plus exact selection; the extension also checks the document UUID |
| Scheme install | `SchemeImportCenter` -> `RecipePackageManager.install` (`installPrefetched` for prefetched sources) |
| Dictionary import | `DictionaryImport.prepareDictionaryImport` -> `installDictionaryImport` |
| Typo correction | `TypoCorrectionCenter` -> `SchemeImportCenter.applyTypoCorrection` -> `TypoCorrection.eligibility`/`make` -> `installRecipePlan` -> engine `schemaValue` read-back -> `performAddKeyboard` (republish). Writes an Rx block into `<schema>.custom.yaml` |
| Prediction | `PredictionCenter` -> `SchemeImportCenter.applyPrediction` -> `Prediction.eligibility`/`make` (Rx block with `predictor` and `predict_translator`, option `prediction`, `predictor/db: songyan-predict.db`, marker `songyan_prediction`; the imported database is installed as a source resource) -> engine read-back -> republish. A composing snapshot with empty input is a prediction state (`EngineSnapshot.isPrediction`); confirm, space, enter, backspace and direct input dismiss it first |
| Lua components | `LuaComponentsCenter` -> `SchemeImportCenter.applyLuaComponents` -> `LuaComponents.state`/`make` (assigns affected `engine/<list>` from the recorded baseline `songyan_lua_baseline` in a custom Rx block) -> republish |
| Grammar model | `GrammarModelSettingsView` / `GrammarModelManagementView` in [GrammarModelManagementView.swift](Apps/HostApp/GrammarModelManagementView.swift) are reachable from Settings > 语法模型 and from a scheme's detail page; one menu per input method picks a model, turns it off or restores the scheme's own setting, and `SchemeImportCenter.applyGrammarChange` installs that choice in one step using the `songyan-models/` Rx namespace. [ModelPublicationState.swift](Packages/PackageManager/Sources/PackageManager/ModelPublicationState.swift) combines installation/publication/model state; a matched runtime receipt describes a past load only. Install and publish are separate steps |
| Publish | `KeyboardRecipeStore.publish` ([KeyboardRecipeStore+Publication.swift](Apps/SharedKeyboard/KeyboardRecipeStore+Publication.swift)) writes a new generation, then `active.json` under `ActiveLock`, then prunes unreferenced generations |
| Manifest read | `ActivationPublishedKeyboardProvider` ([PublishedKeyboardProvider.swift](Apps/SharedKeyboard/PublishedKeyboardProvider.swift)) -> `KeyboardResourceReadQueue` |
| Layouts / appearance | `LayoutManager` -> `layoutStoreDirectory()`; `AppearanceManager` -> `sharedAppearanceStore()`; the extension reads through `layoutStoreReadLocation()` and `sharedAppearanceReadStore()` |
| Quick insert, symbols, paste | `QuickInsertState` -> `QuickInsertCore`; `SymbolLibraryModel` ([SymbolLibraryModel.swift](Apps/SharedKeyboard/SymbolLibraryModel.swift)) -> `SymbolCatalogStore`, shown by [SymbolLibraryView.swift](Apps/SharedKeyboard/SymbolLibraryView.swift); phrases and clipboard history go through `LocalQuickContentModel` ([LocalQuickContentModel.swift](Apps/SharedKeyboard/LocalQuickContentModel.swift)); the panel's band budget is `QuickContentLayout` ([QuickContentLayout.swift](Packages/KeyboardCore/Sources/KeyboardCore/Support/QuickContentLayout.swift)); [QuickPasteView.swift](Apps/SharedKeyboard/QuickPasteView.swift) reads the pasteboard only after a user tap, only when the keyboard is strictly idle |
| Option preferences | `OptionStore` ([OptionStore.swift](Apps/SharedKeyboard/OptionStore.swift)): `OptionPersistenceIO` on a FIFO queue, `OptionPreferenceCache` keyed by resource/schema/name |
| English (ABC) suggestions | `KeyboardController` queries a read-only engine session (`RimeEngine.wordCompletions`, schemas from `table_translator@...` in the current scheme) only while the ABC page is shown; next-word suggestions come from [EnglishNextWord.swift](Packages/KeyboardCore/Sources/KeyboardCore/Support/EnglishNextWord.swift); slot merging is `ABCSuggestionSlots` |
| Learning backup and merge | host `LearningBackupView` -> `LearningTransferStore` slot in the App Group -> `KeyboardLearningTransfer` in the extension (claims the request while the keyboard is visible and uses the engine exclusively) -> receipt in the same store; bridge in `RimeLearningBackup`; see 7.1 |

### Keyboard height

The shell height is budgeted per presentation. `KeyboardViewController` reads the last accepted definition hint in `viewWillAppear` and freezes `presentationShell` until the keyboard is dismissed (`KeyboardInitialPresentation.presentationBudget`, status in the controller-local `ExtensionPresentationStatus`). The single height formula is `KeyboardPanelPresentationBudget` / `presentationShellHeight` in [KeyboardPanelGeometry.swift](Packages/CandidateKit/Sources/CandidateKit/KeyboardPanelGeometry.swift); `KeyboardPanelHeightState` in [KeyboardPanelSizing.swift](Packages/CandidateKit/Sources/CandidateKit/KeyboardPanelSizing.swift) isolates stale requests and receipts per presentation. `KeyboardPanelHost` only fits the current layout and page inside the fixed shell (key rows capped at the standard key height, surplus to the candidate area); a layout switch redraws immediately and the next presentation adopts the new definition's height. Heights are not changed while the keyboard is presented.

### 7.1 Learning backup and merge

The user database (`userdb`) is private to the extension process, so the host submits a request and the extension executes it inside an exclusive-engine window. Backups use librime levers `backup_user_dict` / `restore_user_dict` (`.userdb.txt` snapshots); `export_user_dict` / `import_user_dict` exchange word lists and do not keep decay, tick or deletions. The live LevelDB is never copied.

Fixed slots live under `KeyboardLearning/` in the App Group container (`Slot` in [LearningTransferStore.swift](Packages/KeyboardCore/Sources/KeyboardCore/Support/LearningTransferStore.swift)):

| Slot | Content |
| --- | --- |
| `current.json` | the single authoritative state (<= 16 KiB): id, operation (`backup`/`restore`), status, source identity, `processID` (the execution lease identity), message, `hasSafetyBackup` |
| `restore-input.json` | archive carried by a restore request (written before `current.json`) |
| `backup-output.json` | archive produced by a backup request (written before status `succeeded`) |
| `safety-backup.json` | backup taken before a merge; kept across requests until the next real overwrite |
| `.lock` | short-held cross-process flock guarding state read-modify-write |
| `.worker-lock` | long-held execution lease |

Protocol:

- States: `pending -> running -> succeeded | failed`, plus `cancelled` (only from pending) and `interrupted` (a stale `running` recovered under a new lease). Cancel and claim are mutually exclusive under one flock. A submit never overwrites pending or running.
- Executor writes are compare-and-set on request UUID, `running` and the lease id. Late receipts from an old request or lease are rejected.
- Slot writes are atomic renames; `read()` takes no lock.
- Visibility is checked once per poll and Full Access once per attempt. Just before stopping the keyboard, `EngineOwnershipCoordinator.withExclusive(beforeYield:)` checks controller, resource identity and idle input; the request is claimed only inside the exclusive section.
- Archives ([LearningBackupArchive.swift](Packages/KeyboardCore/Sources/KeyboardCore/Support/LearningBackupArchive.swift)) must have `version` 1 and `producer` `keyboard-extension`; at most 32 dictionaries, each <= 4 MiB, 8 MiB raw in total, 12 MiB encoded; digests are 64-char lowercase hex and checked against the data. Decoding is incremental and rejects the 33rd dictionary before parsing it.
- Merge requires the same source and resource revision, dictionary names matching the engine's declared set and `rime_version`, and a successfully saved safety backup (`completeRestore` enforces it). The merge is librime's own `restore_user_dict`; results are not re-read or re-checked. It is not atomic and not rolled back; `.mergeUnverified` is thrown only after a native write was attempted. The safety backup is for retention and inspection, not rollback.
- [RimeLearningBackup.swift](Packages/RimeBridge/Sources/RimeBridge/RimeLearningBackup.swift) checks imported snapshots only for header, `db_name`, `db_type`, `user_id`, `rime_version` and size caps (32 files, 4 MiB each, 8 MiB total); rows are left to librime. A backup sets the previous `.userdb.txt` in the sync folder aside as `.userdb.txt.prior` and puts it back if the backup fails.
- An empty producer list fails; a fresh empty `userdb` (tick 0, no entries) is a valid payload.

## 8. Storage

Shared container root: the App Group directory; recipe publication lives under `KeyboardRecipes/` (see `KeyboardRecipeStore` in [KeyboardRecipeStore.swift](Apps/SharedKeyboard/KeyboardRecipeStore.swift)).

| Path | Content | Access |
| --- | --- | --- |
| `KeyboardRecipes/active.json` | the only persisted selection record | host writes; host and extension read |
| `KeyboardRecipes/versions/<generation>/resources` | immutable published resources including `build/` | written on publish; only the new and the previous generation are kept |
| `KeyboardRecipes/runtime-grammar-receipt.json` | runtime grammar receipt (`GrammarRuntimeReceiptStore`, [GrammarRuntimeReceiptStore.swift](Apps/SharedKeyboard/GrammarRuntimeReceiptStore.swift)) | |
| `KeyboardRecipes/active.lock` | publish mutual exclusion (`ActiveLock`) | |
| `KeyboardLayouts/` | custom layouts | host writes; extension reads |
| `ShuangpinHints/hints.json` | one bounded snapshot of the enable switch, selected hint preset and at most 64 presets; missing means off, invalid data is rejected; no input codes change | host writes atomically; host/extension read on background queues |
| `KeyboardAppearance/` | unified appearance snapshot | host writes; extension reads |
| `KeyboardOptions/` | option preferences | |
| App Group `UserDefaults` `keyboard.oneHand.v1` | `off` / `left` / `right`, unknown values mean off; adopted on presentation, restore immediately writes off | host writes; host/extension read |
| App Group `UserDefaults` `keyboard.keySoundLevel`, `keyboard.keyHapticLevel` | `soft` / `medium` / `strong`, unknown values mean medium; enable switches remain separate | shared feedback service caches values outside key handling |
| App Group `UserDefaults` `keyboard.heightPreset.v1` | `KeyboardHeightPreferences`, adopted by the next presentation; the same finite height feeds host and extension shell budgets | host writes; host/extension read |
| `LocalQuickContent/content.json` | at most 100 phrases and 20 clipboard strings (4 KiB each); history is off by default and records only successful user-initiated paste; disabling clears it | host/extension use atomic writes and a cross-process lock; iOS file protection, excluded from device backup; phrase export excludes clipboard |
| `DictionaryImportStore/`, `SchemePackages/<id>/` | imported source version directories | install and try-out |
| `KeyboardLearning/` | learning transfer slots (7.1) | host submits and reads; extension executes |
| App Group `UserDefaults` `keyboard.fullAccessSeenAt` | timestamp written by the extension in `viewDidAppear` when full access is on (`KeyboardPresenceStamp`, [KeyboardPresenceStamp.swift](Apps/SharedKeyboard/KeyboardPresenceStamp.swift)) | host reads in onboarding |

Process-private writable directories (Application Support): `RimeUser`, `RimeSchemeUser/<id>`, `RimeLayouts`, `KeyboardAppearanceDrafts`.

The learning database for each source and input method is `<user dir>/<name>.userdb`, written only by the extension (the host try-out uses a different user directory). Restore stages incoming snapshots in `<user dir>/learning-backup-work/` and deletes it afterwards.

Repository-local scratch space `.scratch/` is git-ignored and pruned after 7 days by [prune-scratch.sh](Tools/CI/scripts/prune-scratch.sh) (run by `make prune-scratch`). `.local/` holds build caches and is not pruned.

## 9. Resources

| Path | Content |
| --- | --- |
| [Resources/BuiltinPackages/Basic](Resources/BuiltinPackages/Basic) | built-in schemes `songyan_quanpin` and `songyan_flypy` (`default.yaml`, `manifest.yaml`, `songyan_basic.dict.yaml`) plus their generated 14-, 18- and 9-key companions `keyboard_*.schema.yaml`; in both targets' Resources phase. The extension runs it straight from its bundle when nothing is published (`songyan_quanpin` on the remembered layout; the switcher lists that input method on every layout). The host installs it at launch as the ordinary scheme package `songyan-builtin` (`RecipePackageManager.prepareBundledPackage`, entry schemes only; `SchemeImportCenter.installBuiltinPackage`), so its keyboards are added and published like any import; its learning shares the fallback's user directory. The companions come from `CompactSchemaAdapter.CompanionPlan`; [gen-builtin-companions.sh](Tools/BuildRimeIOS/scripts/gen-builtin-companions.sh) regenerates them and `BuiltinCompanionTests` fails when they are stale |
| [Resources/KeyFeedback](Resources/KeyFeedback), [generate_key_clicks.py](Tools/KeyFeedbackAssets/generate_key_clicks.py) | original 20 ms mono PCM click assets at three amplitudes, copied to both targets; the generator is optional and is not run by the app or build |
| [Resources/Layouts](Resources/Layouts) | example layouts `qwerty26.json`, `merged14.json`, `merged18.json`, `phone9.json`; layouts name no input scheme, and several schemes can share one layout (`BuiltinTemplateSchemas` pairs the built-in templates) |
| [Resources/EngineResources](Resources/EngineResources) | `engine-capabilities.json`, `opencc/`, `licenses/`; host app |
| [Resources/Legal](Resources/Legal) | `ThirdPartyNotices.txt`, `licenses/`; host app |
| [LICENSE](LICENSE), [SECURITY.md](SECURITY.md) | copyright notice and GPL-3.0-only terms for the project's own source; how to report a vulnerability |
| [RimePrelude](Packages/PackageManager/Sources/PackageManager/Resources/RimePrelude) | Rime prelude config (PackageManager resource) |
| [default-symbols.json](Packages/QuickContentKit/Sources/QuickContentKit/Resources/default-symbols.json) | default symbol catalog (QuickContentKit resource) |

## 10. Tests and tools

| Entry | Covers |
| --- | --- |
| [Makefile](Makefile) | `fast` (alias `test`), `extended`, `release`, `structure`, `lint`, `format`, `clean`, `build-simulator`, `build-device`, `prune-scratch`, `sim-stage`, `sim-log`, `sim-state`, `sim-layout`, `sim-probe`, `sim-perf` |
| [Tools/CI/ci.sh](Tools/CI/ci.sh) | `fast`: `Tests/ProjectStructure`, Swift package tests, `Tests/IOS/test_*.py`. `extended`: fast + `Tests/IOS/extended_*.py` + native harnesses + Debug simulator and device builds (unsigned). `release`: extended + `export-rimekit.py --check` + Release simulator and device builds. `lint`: swift-format `--strict`, shellcheck, ruff. `format`: swift-format in place, `ruff check --fix` |
| [test-swift-packages.sh](Tools/CI/scripts/test-swift-packages.sh) | tests of AppearanceKit, CandidateKit, KeyboardCore, LayoutKit, PackageManager, QuickContentKit, SkinKit; build caches in `.local/ci/swift-package-builds/<package>`, logs in `.local/ci/swift-packages/` |
| [build-app.sh](Tools/CI/scripts/build-app.sh) | `Debug\|Release` x `simulator\|device` build of scheme `HostApp`, unsigned (no entitlements; compile check only); `APP_VERSION` / `APP_BUILD` override `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` |
| [package-ipa.sh](Tools/CI/scripts/package-ipa.sh) | the Release device build as an ad-hoc signed IPA with resolved entitlements, for re-signing installers (AltStore, Sideloadly) |
| [sim-stage.sh](Tools/CI/scripts/sim-stage.sh) and the `sim-*.sh` scripts | ad-hoc signed simulator staging, logs, state snapshots, layout override, probes, performance measurement (see [DEBUG.md](DEBUG.md)); [perf_trace.py](Tools/CI/scripts/lib/perf_trace.py) summarises traces |
| [run-native-harnesses.sh](Tools/CI/scripts/run-native-harnesses.sh), [harness.sh](Tools/BuildRimeIOS/scripts/lib/harness.sh) | native macOS harnesses (bridge contracts, T9 letter lock, ambiguity, grammar window); `NATIVE_ENGINE_ROOT` selects a read-only engine prefix, outputs go to `.scratch/native-harnesses/` (`HARNESS_OUTPUT_ROOT` overrides) |
| [Tests/ProjectStructure](Tests/ProjectStructure) | project graph, identity, privacy manifests, artifact and documentation contracts |
| [Tests/IOS](Tests/IOS), [swift_probe.py](Tests/IOS/swift_probe.py) | production-source Swift probes compiled and run offline; fixtures in [Tests/IOS/Fixtures](Tests/IOS/Fixtures); compiled module cache in `.local/swift-probes/` |
| [Tests/EngineFixtures](Tests/EngineFixtures), [Tests/Fixtures](Tests/Fixtures) | engine fixtures, grammar ranking fixtures |
| [Tools/BuildRime](Tools/BuildRime), [Tools/BuildRimeIOS](Tools/BuildRimeIOS) | macOS engine prefix; iOS engine build, export and harnesses (`harness-mac/`) |
| [14-build-host-opencc.sh](Tools/BuildRimeIOS/scripts/14-build-host-opencc.sh), [host-tools.sh](Tools/BuildRimeIOS/scripts/lib/host-tools.sh), [opencc-dict-emulator.sh](Tools/BuildRimeIOS/scripts/lib/opencc-dict-emulator.sh) | pinned macOS `opencc_dict` in `IOS_ROOT/prefix-mac`, recorded artifact identity and real dictionary conversion checks; [11-build-deps.sh](Tools/BuildRimeIOS/scripts/11-build-deps.sh) ensures it automatically and supplies the CMake host wrapper for both iOS slices |
| [KeyboardLifecycleDiagnostics.swift](Apps/SharedKeyboard/KeyboardLifecycleDiagnostics.swift) | `#if DEBUG` `DebugProbe`: environment line, signposts, slow-op log, state snapshots; contains no user input |
| [KeyboardLog.swift](Apps/SharedKeyboard/KeyboardLog.swift) | `Logger` categories of both targets under subsystem `app.songyan.ime` (packages declare their own with the same subsystem) |
| [.github/workflows/ci.yml](.github/workflows/ci.yml), [dependabot.yml](.github/dependabot.yml) | Xcode 27.1 on the `xcode-27` image. Pull requests and pushes to main (docs-only changes skipped): `Tools/CI/ci.sh lint`, `Tools/CI/ci.sh fast`, unsigned Release device build. Release tags: lint, tests and the Debug device build. Manual runs: lint, tests and both device builds. Caches are saved only from main. Dependabot bumps the pinned actions monthly |
| [.github/workflows/release.yml](.github/workflows/release.yml) | on a `vX.Y.Z` tag (`vX.Y.Z-suffix` is a pre-release) of a main commit: full `ci.yml`, then a Release device build versioned from the tag (build number = commit count), `package-ipa.sh`, and a GitHub Release with the IPA and generated notes |

## 11. Platform boundaries

| Boundary | Fact | Source |
| --- | --- | --- |
| Full access | Without full access the extension can still read the App Group but cannot write the shared container or use the network | [Configuring open access](https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard) |
| Text interaction | The document context window is not the whole document; secure fields, phone pads and hosts that refuse third-party keyboards are platform limits | [Handling text interactions](https://developer.apple.com/documentation/uikit/handling-text-interactions-in-custom-keyboards) |
| Layout and memory | Must adapt to widths, iPad floating and orientation; memory limits vary by device | [Creating a custom keyboard](https://developer.apple.com/documentation/uikit/creating-a-custom-keyboard) |
| App Review 4.4.1 | Basic function and keyboard switching must work without full access | [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) |
| Password settings | `ASSettingsHelper.openCredentialProviderAppSettings` only navigates; it does not mean a provider is enabled | [API reference](https://developer.apple.com/documentation/authenticationservices/assettingshelper/opencredentialproviderappsettings(completionhandler:)) |
| User dictionary APIs | `backup_user_dict`/`restore_user_dict` differ from `export_user_dict`/`import_user_dict` (the latter drops decay, tick and deletions) | [levers API](https://github.com/rime/librime/blob/1.17.0/src/rime_levers_api.h) |
