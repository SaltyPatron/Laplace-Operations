@echo off
call "C:\Program Files (x86)\Intel\oneAPI\setvars.bat" intel64 vs2022 > "E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z\native-env.log" 2>&1
if errorlevel 1 exit /b %errorlevel%
cmake -S "E:\Repositories\Laplace\Laplace-Native" -B "E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z\native-build" -G Ninja -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icx -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLAPLACE_SRC="E:\Repositories\Laplace" -DLAPLACE_OPERATIONS="E:\Repositories\Laplace\Laplace-Operations" -DLAPLACE_BLAKE3_DIR=D:/Libraries/src/blake3/c -DLAPLACE_COREMATH=D:/Libraries/src/core-math -DLAPLACE_ICU_DIR=D:/Libraries/icu/78.3 -DLAPLACE_EIGEN_DIR=D:/Libraries/src/eigen -DLAPLACE_SPECTRA_DIR=D:/Libraries/src/spectra -DLAPLACE_TREESITTER=D:/Libraries/src/tree-sitter -DLAPLACE_TIER0="E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z\native-candidate-tier0.bin"
if errorlevel 1 exit /b %errorlevel%
cmake --build "E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z\native-build" --target laplace_tier0 test_tier0 test_identity test_coord test_core test_ids test_text
if errorlevel 1 exit /b %errorlevel%
"E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z\native-build\laplace-tier0.exe" E:/Data/Ingest/UCD/Public/UCD/latest "E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z\native-candidate-tier0.bin"
if errorlevel 1 exit /b %errorlevel%
set "PATH=D:\Libraries\icu\78.3\bin64;%PATH%"
ctest --test-dir "E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z\native-build" --output-on-failure -R "^(test_tier0|identity|coord|core|test_ids|text)$" --output-junit "E:\Repositories\Laplace\artifacts\repository-cleanup-2026-10-31T04-53-01-772Z\native-windows.xml"
exit /b %errorlevel%
