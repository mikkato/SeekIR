#!/bin/bash
# TEST-02/03: синтетические измерения + координаты (без камеры)
set -e
cd "$(dirname "$0")"
mkdir -p build
swiftc -O Tests/main.swift \
  Sources/Inspection/MeasurementService.swift \
  Sources/Inspection/CoordinateSpace.swift \
  Sources/Inspection/Models.swift \
  Sources/Inspection/ProjectStore.swift \
  -o build/meas-tests
./build/meas-tests
