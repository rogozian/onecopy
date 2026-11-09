# ONECOPY · GitHub-аудит способов установки IPA на iPhone

**Дата проверки: 9 ноября 2026 года.** Задача — установить собственный `ONECOPY-iPhone-UNSIGNED-NOT-INSTALLABLE.ipa` из [официального релиза](https://github.com/rogozian/onecopy/releases/tag/ios-qa-0.3) на iOS 27 без собственного компьютера и без платной Apple Developer Program.

**Вывод:** множество GitHub-проектов решает *подпись уже установленным подписывающим приложением*, но не проблему **первоначальной установки** подписывающего приложения. Из проверенных путей без компьютера на iOS 27 основные кандидаты — AltLoad и SideInstaller с официальной временной подписью. Текущий сайт SideInstaller предоставляет OTA-манифесты: наличие файла и срок окончания сертификата не доказывают отсутствие отзыва Apple.

## A. Первоначальная установка — главный приоритет

| Репозиторий | Метод | Первоначально без ПК? | Что подтверждено |
| --- | --- | --- | --- |
| [FrizzleM/SideInstaller](https://github.com/FrizzleM/SideInstaller) | Официальный подписанный bootstrap → собственный бесплатный Apple ID → SideStore или прямой импорт IPA | **Заявлен: да, iOS 27+** | Сайт, 2 OTA-манифеста и соответствующие IPA из [официального релиза v1.6.5](https://github.com/FrizzleM/SideInstaller-Signed/releases/tag/v1.6.5) проверены 09.11; работоспособность сертификата **на устройстве не доказана** |
| [mirazbakis/AltLoad](https://github.com/mirazbakis/AltLoad) | Общий bootstrap → самосопряжение на iOS 27 → бесплатный Apple ID/LocalDevVPN → установка IPA | **Заявлен: да, iOS 27+** | Официальный сайт [AltLoad](https://mirazbakis.github.io/AltLoad/) перечисляет 32 варианта подписи, но нет гарантии отзыва |
| [FrizzleM/SideInstaller/ish](https://github.com/FrizzleM/SideInstaller/blob/main/ish/README.md) | iSH из App Store компилирует zsign, регистрирует личный бесплатный сертификат, пытается установить подписанный IPA через HTTPS и `itms-services` | **Возможен, но экспериментальный** | Автор **сам указывает**, что полный процесс входа в Apple ID и установка на реальном iPhone НЕ проверены. Нельзя называть рабочим решением |
| [Apparition](https://github.com/illixion/Apparition) | Apple ID и фоновая переподпись | **Нет** | Первоначально нужен Windows/Linux/Mac и сопряжение, потом без ПК |
| [SideStore/SideStore](https://github.com/SideStore/SideStore) | Установка и обновление IPA | **После bootstrap** | Нужен SideInstaller/AltLoad либо первичная установка с ПК |
| [altstoreio/AltStore](https://github.com/altstoreio/AltStore) | Бесплатный Apple ID, AltServer/refresh | **После bootstrap** | Нужна первичная установка и подпись |
| [StikDebug/StikDebug](https://github.com/StikDebug/StikDebug) | Локальный отладчик, pairing, JIT | **Не самостоятельный IPA-bootstrap** | Нужны уже установленная программа, сопряжение и VPN |

### Подтверждённые официальные файлы SideInstaller v1.6.5

- [Jiangsu Simcere / workone — официальный OTA-манифест](https://sideinstaller.net/stable/sideinstaller-Jiangsu-Simcere-Pharmaceutical-Co.-Ltd-workone.plist) → подписанный файл в `FrizzleM/SideInstaller-Signed`.
- [Moving Increasingly Interconnected Technology / com.oa11 — официальный OTA-манифест](https://sideinstaller.net/stable/sideinstaller-Moving-Increasingly-Interconnected-Technology-Co.-Ltd-com.oa11.plist) → подписанный файл в том же релизе.
- [Официальная страница установки](https://sideinstaller.net/) предлагает DNS-конфигурацию. Не устанавливать профили неизвестных копий и зеркал.
- **Подтверждены HTTPS-манифесты и наличие IPA. Не подтверждена OCSP-проверка и возможность установки на физическом iPhone.** Дата окончания сертификата — не гарантия отсутствия отзыва.

## B. Мобильные подписывающие программы: нужен сертификат P12 либо уже установленный signer

| Репозиторий | Возможности | Почему не решает первоначальную установку |
| --- | --- | --- |
| [NexSideloading/NexStore](https://github.com/NexSideloading/NexStore) | IPA + AltStore источники, проверка OCSP | Нужна пара сертификат/профиль; Apple ID signing пока заявлен на будущее |
| [claration/feather](https://github.com/claration/feather) | Подпись P12 и локальная установка IPA | Требует сертификат и установку Feather |
| [Nyasami/Ksign](https://github.com/Nyasami/Ksign) | Подписывание IPA на устройстве | Нужен сертификат |
| [faroukbmiled/RyukSign](https://github.com/faroukbmiled/RyukSign) | Fork Feather, установка, каталог | Нужен сертификат |
| [Mesutcydev/ForgeSign-iOS](https://github.com/Mesutcydev/ForgeSign-iOS) | zsign + локальный OTA-манифест | Нужен P12/mobileprovision и установка самого ForgeSign |
| [8yy/BatSign](https://github.com/8yy/BatSign) | Fork Feather, обновления | Нужен сертификат |
| [cc158999/EnSign](https://github.com/cc158999/EnSign) | Мобильный signer | Нужен сертификат |
| [ihateios/SignOs](https://github.com/ihateios/SignOs) | Fork Feather, обновления, клоны | Нужен сертификат |
| [xsxs18-dev/SwiftIPA](https://github.com/xsxs18-dev/SwiftIPA) | Мобильный signer и импорт IPA | Нужен сертификат; проверить внешние серверы |
| [dylldev/wax-signer](https://github.com/dylldev/wax-signer) | Минимальный мобильный signer | Ранняя стадия и нужен сертификат |
| [DebianArch64/Scarlet](https://github.com/DebianArch64/Scarlet) | Прямая/сертификатная установка | Общие сертификаты могут быть отозваны; первичная установка не гарантирована |

## C. Вспомогательные альтернативы и инструменты, которые не снимают барьер

| Репозиторий | Назначение | Ограничение |
| --- | --- | --- |
| [huzaifah1530-bot/SideKick](https://github.com/huzaifah1530-bot/SideKick) | SideStore-форк с библиотекой IPA и GitHub Releases | Нужна первоначальная установка, ранний prerelease |
| [lungustefan/MultiStore](https://github.com/lungustefan/MultiStore) | Несколько Apple ID, refresh | Всё ещё пределы Apple и bootstrap |
| [LiveContainer/LiveContainer](https://github.com/LiveContainer/LiveContainer) | Запуск нескольких guest IPA внутри подписанного контейнера | Сам контейнер должен быть установлен и подписан; совместимость приложений ограничена |
| [opa334/TrollStore](https://github.com/opa334/TrollStore) | Постоянная установка на поддерживаемых старых iOS | Не метод для стандартной iOS 27 |
| [AhmedBafkir/DLiPA](https://github.com/AhmedBafkir/DLiPA) | Доступ к авторизованным App Store приложениям | Не подписывает произвольный собственный IPA |
| [pwnapplehat/iPASide](https://github.com/pwnapplehat/iPASide) | Бесплатный Windows signer с Apple ID | Требуется Windows + Apple Devices/iTunes |
| [nab138/iloader](https://github.com/nab138/iloader) | Сопряжение и установка SideStore/IPA | Требуется ПК (Windows/Mac/Linux) |
| [illixion/Apparition](https://github.com/illixion/Apparition) | Кроссплатформенный bootstrap, обновления на устройстве | Требуется ПК однократно |
| [NexSideloading/certificates](https://github.com/NexSideloading/certificates) | Публичные наборы корпоративных сертификатов | Объявленные сертификаты могут быть отозваны; не загружать чужие P12 в сомнительные сервисы |

## D. Закрытые или платные сервисы

- [Signulous](https://www.signulous.com/): платная регистрация устройства и подпись IPA с iPhone.
- [appdb](https://appdb.to/): установка через web-каталог при наличии подходящей подписи.
- Недорогие сторонние продавцы сертификатов: **не проверены независимой установкой**, оплата и обещания не равны успешной подписи. Утечка P12 или отзыв сертификата — отдельные риски.

## E. Что реально выполнено для ONECOPY

1. Собраны нативный iOS-проект, симулятор и неподписанный device IPA; проверка на реальном iPhone **не выполнена**.
2. Оригинальный [ONECOPY IPA 0.3](https://github.com/rogozian/onecopy/releases/tag/ios-qa-0.3) загружен в GitHub Releases.
3. [Собственный AltStore/SideStore каталог](https://rogozian.github.io/onecopy/altsource.json) размещён на GitHub Pages и проверен на корректность формата.
4. [Центр установки ONECOPY](https://rogozian.github.io/onecopy/install.html) содержит официальные источники, SideInstaller OTA-манифесты, AltLoad и запасные маршруты.
5. Ничего не перепаковывается из AltLoad/SideInstaller: их лицензии ограничивают повторное распространение.

**Приоритет сейчас:** официальный SideInstaller 1.6.5 с опубликованными OTA-файлами или официальный AltLoad с доступной первоначальной подписью. Любой способ без подтверждённой Apple-подписи, который обещает установку на iOS 27 «одним кликом», следует считать неподтверждённым. После установки нельзя массово удалять важные данные ONECOPY до физического тестирования сканирования и отката.

Источники: [curated GitHub-каталог](https://github.com/lgg/awesome-ios-sideloading), официальные README и релизы каждого проекта.
