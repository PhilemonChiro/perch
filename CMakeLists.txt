cmake_minimum_required(VERSION 3.21)
project(Relay VERSION 0.1.0 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 6.9 REQUIRED COMPONENTS Gui Quick QuickControls2)
find_package(Qt6Keychain REQUIRED)
find_package(WinPR 3 REQUIRED)
find_package(FreeRDP 3 REQUIRED)
find_package(FreeRDP-Client 3 REQUIRED)

qt_standard_project_setup(REQUIRES 6.9)

qt_add_executable(relay WIN32 MACOSX_BUNDLE
    src/main.cpp
)

set_source_files_properties(qml/Theme.qml PROPERTIES QT_QML_SINGLETON_TYPE TRUE)

file(GLOB RELAY_ICONS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} icons/*.svg)

qt_add_qml_module(relay
    URI Relay
    VERSION 1.0
    SOURCES
        src/ConnectionStore.h src/ConnectionStore.cpp
        src/Credentials.h src/Credentials.cpp
        src/SessionManager.h src/SessionManager.cpp
        src/RdpSession.h src/RdpSession.cpp
        src/RdpView.h src/RdpView.cpp
    QML_FILES
        qml/Main.qml
        qml/Theme.qml
        qml/Sidebar.qml
        qml/TabStrip.qml
        qml/Home.qml
        qml/SessionPage.qml
        qml/CommandPalette.qml
        qml/ConnectionEditor.qml
        qml/components/Icon.qml
        qml/components/IconButton.qml
        qml/components/PrimaryButton.qml
        qml/components/GhostButton.qml
        qml/components/Field.qml
        qml/components/Spinner.qml
        qml/components/StatusDot.qml
        qml/components/Card.qml
        qml/components/Toast.qml
        qml/components/Toggle.qml
    RESOURCES ${RELAY_ICONS}
)

target_include_directories(relay PRIVATE src)

target_link_libraries(relay PRIVATE
    Qt6::Gui Qt6::Quick Qt6::QuickControls2
    Qt6Keychain::Qt6Keychain
    winpr freerdp freerdp-client
)

set_target_properties(relay PROPERTIES
    OUTPUT_NAME Relay
    MACOSX_BUNDLE_GUI_IDENTIFIER io.relay.app
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
)

install(TARGETS relay BUNDLE DESTINATION . RUNTIME DESTINATION bin)
