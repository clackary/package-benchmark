//
// Copyright (c) 2022 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

import DateTime
import Progress

#if canImport(OSLog)
    import OSLog
#endif

final class BenchmarkExecutor { // swiftlint:disable:this type_body_length
    init(quiet: Bool = false) {
        self.quiet = quiet
    }

    var quiet: Bool
    let operatingSystemStatsProducer = OperatingSystemStatsProducer()

    // swiftlint:disable cyclomatic_complexity function_body_length
    func run(_ benchmark: Benchmark) -> [BenchmarkResult] {
        var wallClockDuration: Duration = .zero
        var startMallocStats = MallocStats()
        var stopMallocStats = MallocStats()
        var startOperatingSystemStats = OperatingSystemStats()
        var stopOperatingSystemStats = OperatingSystemStats()
        var startARCStats = ARCStats()
        var stopARCStats = ARCStats()
        var startTime = BenchmarkClock.now
        var stopTime = BenchmarkClock.now

        // optionally run a few warmup iterations by default to clean out outliers due to cacheing etc.

        #if canImport(OSLog)
            let logHandler = OSLog(subsystem: "one.ordo.benchmark", category: .pointsOfInterest)
            let signPost = OSSignposter(logHandle: logHandler)
            let signpostID = OSSignpostID(log: logHandler)
            var warmupInterval: OSSignpostIntervalState?

            if benchmark.configuration.warmupIterations > 0 {
                warmupInterval = signPost.beginInterval("Benchmark", id: signpostID, "\(benchmark.name) warmup")
            }
        #endif

        for iterations in 0 ..< benchmark.configuration.warmupIterations {
            benchmark.currentIteration = iterations
            benchmark.run()
        }

        #if canImport(OSLog)
            if let warmupInterval {
                signPost.endInterval("Benchmark", warmupInterval, "\(benchmark.configuration.warmupIterations)")
            }
        #endif

        // Could make an array with raw value indexing on enum for
        // performance if needed instead of dictionary
        var statistics: [BenchmarkMetric: Statistics] = [:]
        var operatingSystemStatsRequested = false
        var mallocStatsRequested = false
        var arcStatsRequested = false
        var operatingSystemMetricsRequested: Set<BenchmarkMetric> = []

        // Create metric statistics as needed
        benchmark.configuration.metrics.forEach { metric in
            switch metric {
            case .custom:
                statistics[metric] = Statistics(prefersLarger: metric.polarity == .prefersLarger)
            case .wallClock, .cpuUser, .cpuTotal, .cpuSystem:
                let units = Statistics.Units(benchmark.configuration.timeUnits)
                statistics[metric] = Statistics(units: units)
            default:
                if operatingSystemStatsProducer.metricSupported(metric) == true {
                    statistics[metric] = Statistics(prefersLarger: metric.polarity == .prefersLarger)
                }
            }

            if mallocStatsProducerNeeded(metric) {
                mallocStatsRequested = true
            }

            if operatingSystemsStatsProducerNeeded(metric), operatingSystemStatsProducer.metricSupported(metric) {
                operatingSystemMetricsRequested.insert(metric)
                operatingSystemStatsRequested = true
            }

            if arcStatsProducerNeeded(metric) {
                arcStatsRequested = true
            }
        }

        operatingSystemStatsProducer.configureMetrics(operatingSystemMetricsRequested)

        var iterations = 0
        let initialStartTime = BenchmarkClock.now

        // 'Warmup' to remove initial mallocs from stats in p100
        if mallocStatsRequested {
            _ = MallocStatsProducer.makeMallocStats()
        }

        // Calculate typical sys call check overhead and deduct that to get 'clean' stats for the actual benchmark
        var operatingSystemStatsOverhead = OperatingSystemStats()
        if operatingSystemStatsRequested {
            let statsOne = operatingSystemStatsProducer.makeOperatingSystemStats()
            let statsTwo = operatingSystemStatsProducer.makeOperatingSystemStats()

            operatingSystemStatsOverhead.syscalls = statsTwo.syscalls - statsOne.syscalls
            operatingSystemStatsOverhead.readSyscalls = statsTwo.readSyscalls - statsOne.readSyscalls
            operatingSystemStatsOverhead.readBytesLogical = statsTwo.readBytesLogical - statsOne.readBytesLogical
            operatingSystemStatsOverhead.readBytesPhysical = statsTwo.readBytesPhysical - statsOne.readBytesPhysical
        }

        // Hook that is called before the actual benchmark closure run, so we can capture metrics here
        // NB this code may be called twice if the user calls startMeasurement() manually and should
        // then reset to a new starting state.
        // NB that the order is important, as we will get leaked
        // ARC measurements if initializing it before malloc etc.
        benchmark.measurementPreSynchronization = {
            if operatingSystemStatsRequested {
                startOperatingSystemStats = self.operatingSystemStatsProducer.makeOperatingSystemStats()
            }

            if mallocStatsRequested {
                startMallocStats = MallocStatsProducer.makeMallocStats()
            }

            if arcStatsRequested {
                startARCStats = ARCStatsProducer.makeARCStats()
            }

            startTime = BenchmarkClock.now // must be last in closure
        }

        // And corresponding hook for then the benchmark has finished and capture finishing metrics here
        // This closure will only be called once for a given run though.
        benchmark.measurementPostSynchronization = {
            stopTime = BenchmarkClock.now // must be first in closure

            if arcStatsRequested {
                stopARCStats = ARCStatsProducer.makeARCStats()
            }

            if mallocStatsRequested {
                stopMallocStats = MallocStatsProducer.makeMallocStats()
            }

            if operatingSystemStatsRequested {
                stopOperatingSystemStats = self.operatingSystemStatsProducer.makeOperatingSystemStats()
            }

            var delta = 0
            let runningTime: Duration = startTime.duration(to: stopTime)

            wallClockDuration = initialStartTime.duration(to: stopTime)

            if runningTime > .zero { // macOS sometimes gives us identical timestamps so let's skip those.
                statistics[.wallClock]?.add(Int(runningTime.nanoseconds()))

                var roundedThroughput =
                    Double(1_000_000_000)
                        / Double(runningTime.nanoseconds())
                roundedThroughput.round(.toNearestOrAwayFromZero)

                let throughput = Int(roundedThroughput)

                if throughput > 0 {
                    statistics[.throughput]?.add(throughput)
                }
            } else {
                //  fatalError("Zero running time \(self.startTime), \(self.stopTime), \(runningTime)")
            }

            if arcStatsRequested {
                let objectAllocDelta = stopARCStats.objectAllocCount - startARCStats.objectAllocCount
                statistics[.objectAllocCount]?.add(Int(objectAllocDelta))

                let retainDelta = stopARCStats.retainCount - startARCStats.retainCount - 1 // due to some ARC traffic in the path
                statistics[.retainCount]?.add(Int(retainDelta))

                let releaseDelta = stopARCStats.releaseCount - startARCStats.releaseCount - 1 // due to some ARC traffic in the path
                statistics[.releaseCount]?.add(Int(releaseDelta))

                statistics[.retainReleaseDelta]?.add(Int(abs(objectAllocDelta + retainDelta - releaseDelta)))
            }

            if mallocStatsRequested {
                delta = stopMallocStats.mallocCountTotal - startMallocStats.mallocCountTotal
                statistics[.mallocCountTotal]?.add(Int(delta))

                delta = stopMallocStats.mallocCountSmall - startMallocStats.mallocCountSmall
                statistics[.mallocCountSmall]?.add(Int(delta))

                delta = stopMallocStats.mallocCountLarge - startMallocStats.mallocCountLarge
                statistics[.mallocCountLarge]?.add(Int(delta))

                delta = stopMallocStats.allocatedResidentMemory -
                    startMallocStats.allocatedResidentMemory
                statistics[.memoryLeaked]?.add(Int(delta))

                statistics[.allocatedResidentMemory]?.add(Int(stopMallocStats.allocatedResidentMemory))
            }

            if operatingSystemStatsRequested {
                delta = stopOperatingSystemStats.cpuUser - startOperatingSystemStats.cpuUser
                statistics[.cpuUser]?.add(Int(delta))

                delta = stopOperatingSystemStats.cpuSystem - startOperatingSystemStats.cpuSystem
                statistics[.cpuSystem]?.add(Int(delta))

                delta = stopOperatingSystemStats.cpuTotal -
                    startOperatingSystemStats.cpuTotal
                statistics[.cpuTotal]?.add(Int(delta))

                delta = stopOperatingSystemStats.peakMemoryResident
                statistics[.peakMemoryResident]?.add(Int(delta))

                delta = stopOperatingSystemStats.peakMemoryVirtual
                statistics[.peakMemoryVirtual]?.add(Int(delta))

                delta = stopOperatingSystemStats.syscalls -
                    startOperatingSystemStats.syscalls - operatingSystemStatsOverhead.syscalls
                statistics[.syscalls]?.add(Int(max(0, delta)))

                delta = stopOperatingSystemStats.contextSwitches -
                    startOperatingSystemStats.contextSwitches
                statistics[.contextSwitches]?.add(Int(delta))

                delta = stopOperatingSystemStats.threads
                statistics[.threads]?.add(Int(delta))

                delta = stopOperatingSystemStats.threadsRunning
                statistics[.threadsRunning]?.add(Int(delta))

                delta = stopOperatingSystemStats.readSyscalls -
                    startOperatingSystemStats.readSyscalls - operatingSystemStatsOverhead.readSyscalls
                statistics[.readSyscalls]?.add(Int(max(0, delta)))

                delta = stopOperatingSystemStats.writeSyscalls -
                    startOperatingSystemStats.writeSyscalls
                statistics[.writeSyscalls]?.add(Int(delta))

                delta = stopOperatingSystemStats.readBytesLogical -
                    startOperatingSystemStats.readBytesLogical - operatingSystemStatsOverhead.readBytesLogical
                statistics[.readBytesLogical]?.add(Int(max(0, delta)))

                delta = stopOperatingSystemStats.writeBytesLogical -
                    startOperatingSystemStats.writeBytesLogical
                statistics[.writeBytesLogical]?.add(Int(delta))

                delta = stopOperatingSystemStats.readBytesPhysical -
                    startOperatingSystemStats.readBytesPhysical - operatingSystemStatsOverhead.readBytesPhysical
                statistics[.readBytesPhysical]?.add(Int(max(0, delta)))

                delta = stopOperatingSystemStats.writeBytesPhysical -
                    startOperatingSystemStats.writeBytesPhysical
                statistics[.writeBytesPhysical]?.add(Int(delta))
            }
        }

        benchmark.customMetricMeasurement = { metric, value in
            statistics[metric]?.add(value)
        }

        if benchmark.configuration.metrics.contains(.threads) ||
            benchmark.configuration.metrics.contains(.threadsRunning) {
            operatingSystemStatsProducer.startSampling(5_000) // ~5 ms
        }

        var progressBar: ProgressBar?

        if quiet == false {
            let progressString = "| \(benchmark.target):\(benchmark.name)"

            progressBar = ProgressBar(count: 100,
                                      configuration: [ProgressPercent(),
                                                      ProgressBarLine(barLength: 60),
                                                      ProgressTimeEstimates(),
                                                      ProgressString(string: progressString)])
            if var progressBar {
                progressBar.setValue(0)
            }
        }

        var nextPercentageToUpdateProgressBar = 0

        if arcStatsRequested {
            ARCStatsProducer.hook()
        }

        #if canImport(OSLog)
            let benchmarkInterval = signPost.beginInterval("Benchmark", id: signpostID, "\(benchmark.name)")
        #endif

        // Run the benchmark at a minimum the desired iterations/runtime --

        while iterations <= benchmark.configuration.maxIterations ||
            wallClockDuration <= benchmark.configuration.maxDuration {
            // and at a maximum the same...
            guard wallClockDuration < benchmark.configuration.maxDuration,
                  iterations < benchmark.configuration.maxIterations
            else {
                break
            }

            if benchmark.failureReason != nil {
                return []
            }

            benchmark.currentIteration = iterations + benchmark.configuration.warmupIterations

            benchmark.run()

            iterations += 1

            if var progressBar {
                let iterationsPercentage = 100.0 * Double(iterations) /
                    Double(benchmark.configuration.maxIterations)

                let timePercentage = 100.0 * (wallClockDuration /
                    benchmark.configuration.maxDuration)

                let maxPercentage = max(iterationsPercentage, timePercentage)

                // Small optimization to not update every single percentage point
                if Int(maxPercentage) > nextPercentageToUpdateProgressBar {
                    progressBar.setValue(Int(maxPercentage))
                    nextPercentageToUpdateProgressBar = Int(maxPercentage) + Int.random(in: 3 ... 9)
                }
            }
        }

        #if canImport(OSLog)
            signPost.endInterval("Benchmark", benchmarkInterval, "\(iterations)")
        #endif

        if arcStatsRequested {
            ARCStatsProducer.unhook()
        }

        if var progressBar {
            progressBar.setValue(100)
        }

        if benchmark.configuration.metrics.contains(.threads) ||
            benchmark.configuration.metrics.contains(.threadsRunning) {
            operatingSystemStatsProducer.stopSampling()
        }

        // construct metric result array
        var results: [BenchmarkResult] = []
        statistics.forEach { key, value in
            if value.measurementCount > 0 {
                let result = BenchmarkResult(metric: key,
                                             timeUnits: BenchmarkTimeUnits(value.timeUnits),
                                             scalingFactor: benchmark.configuration.scalingFactor,
                                             warmupIterations: benchmark.configuration.warmupIterations,
                                             thresholds: benchmark.configuration.thresholds?[key],
                                             statistics: value)
                results.append(result)
            }
        }

        // sort on metric descriptions for now to get predicatable output on screen
        results.sort(by: { $0.metric.description > $1.metric.description })

        return results
    }
}

// swiftlint:enable cyclomatic_complexity function_body_length
