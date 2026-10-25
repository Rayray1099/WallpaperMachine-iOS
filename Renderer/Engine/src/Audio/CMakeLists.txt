set(LIB_NAME wpAudio)

if(NOT TARGET wmSound)
    message(FATAL_ERROR "wpAudio needs wmSound (Renderer/Sound in this repository)")
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    # Miniaudio's iOS backend is Objective-C++ (AVAudioSession / @autoreleasepool),
    # but its implementation is emitted from this translation unit.
    set_source_files_properties(SoundManager.cpp PROPERTIES LANGUAGE OBJCXX)
endif()

add_library(${LIB_NAME}
    STATIC
    BinaryStreamByteSource.cpp
    PcmSoundStream.cpp
    AudioResponseAnalyzerVdsp.cpp
    AudioResponseService.cpp
    SoundManager.cpp
    SoundStreamFactory.cpp
)

if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    set_target_properties(${LIB_NAME} PROPERTIES OBJCXX_STANDARD 20 OBJCXX_STANDARD_REQUIRED YES)
    target_compile_options(${LIB_NAME} PRIVATE "$<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>")
endif()

target_link_libraries(${LIB_NAME}
PUBLIC
    wpUtils
    wmSound
PRIVATE
    wpFs
    miniaudio
)
target_include_directories(${LIB_NAME} PUBLIC include PRIVATE include/Audio)
target_compile_options(${LIB_NAME} PRIVATE ${warn_opts})
if(BUILD_TESTS)
    target_compile_definitions(${LIB_NAME} PRIVATE WESCENE_BUILD_TESTS=1)
endif()
set_property(TARGET ${LIB_NAME} PROPERTY POSITION_INDEPENDENT_CODE ON)
