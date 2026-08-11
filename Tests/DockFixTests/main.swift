let run = TestRun()

run.suite("Geometry: correction table", geometryTable)
run.suite("Geometry: idempotence", geometryIdempotence)
run.suite("Geometry: result always inside usable area", geometryAlwaysInside)
run.suite("Geometry: log formatting", geometryLogFormatting)
run.suite("ScreenMap: coordinate conversion", screenMapConversion)

run.finish()
