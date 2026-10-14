cmake_minimum_required(VERSION 3.21)
project(Relay VERSION 0.1.1 LANGUAGES C CXX)

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
        src/CredentialStore.h src/CredentialStore.cpp
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
        qml/CredentialManager.qml
        qml/CredentialPicker.qml
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

# WinPR/FreeRDP headers pull in <windows.h>; NOMINMAX keeps its min/max macros
# from clobbering std::min/std::max. WIN32_LEAN_AND_MEAN trims the include.
if(WIN32)
    target_compile_definitions(relay PRIVATE NOMINMAX WIN32_LEAN_AND_MEAN)
endif()

target_link_libraries(relay PRIVATE
    Qt6::Gui Qt6::Quick Qt6::QuickControls2
    Qt6Keychain::Qt6Keychain
    winpr freerdp freerdp-client
)

# The output binary is "Perch". (The QML module dir is "Relay", so there is no
# collision with the Linux executable name.)
set_target_properties(relay PROPERTIES OUTPUT_NAME Perch)

set_target_properties(relay PROPERTIES
    MACOSX_BUNDLE_GUI_IDENTIFIER io.relay.app
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
)

# App/dock icon (the Perch bird) for the macOS bundle.
if(APPLE)
    set(PERCH_ICNS ${CMAKE_CURRENT_SOURCE_DIR}/macos/Perch.icns)
    set_source_files_properties(${PERCH_ICNS} PROPERTIES MACOSX_PACKAGE_LOCATION "Resources")
    target_sources(relay PRIVATE ${PERCH_ICNS})
    set_target_properties(relay PROPERTIES MACOSX_BUNDLE_ICON_FILE "Perch")
endif()

# Sign the bundle with a stable identity so the macOS keychain "Always Allow"
# grant survives rebuilds (ad-hoc signatures change every build and re-prompt).
# Configure with -DRELAY_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)".
if(APPLE AND RELAY_CODESIGN_IDENTITY)
    add_custom_command(TARGET relay POST_BUILD
        COMMAND codesign --force --sign "${RELAY_CODESIGN_IDENTITY}"
                --identifier io.relay.app --timestamp=none
                "$<TARGET_BUNDLE_DIR:relay>"
        COMMENT "Code-signing Relay.app with ${RELAY_CODESIGN_IDENTITY}"
        VERBATIM)
endif()

install(TARGETS relay BUNDLE DESTINATION . RUNTIME DESTINATION bin)
