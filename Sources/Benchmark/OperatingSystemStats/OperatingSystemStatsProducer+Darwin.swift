//
// Copyright (c) 2022 Ordo One AB.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
//
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)

    import CDarwinOperatingSystemStats
    import Darwin
    import Dispatch

    final class OperatingSystemStatsProducer {
        var nsPerMachTick: Double
        var nsPerSchedulerTick: Int

        let lock = NIOLock()
        let semaphore = DispatchSemaphore(value: 0)
        var peakThreads: Int = 0
        var peakThreadsRunning: Int = 0
        var runState: RunState = .running
        var sampleRate: Int = 10_000
        var metrics: Set<BenchmarkMetric>?
        var pid = getpid()

        enum RunState {
            case running
            case shuttingDown
            case done
        }

        internal
        final class CallbackDataCarrier<T> {
            init(_ data: T) {
                self.data = data
            }

            var data: T
        }

        init() {
            var info = mach_timebase_info_data_t()

            mach_timebase_info(&info)

            nsPerMachTick = Double(info.numer) / Double(info.denom)

            let schedulerTicksPerSecond = sysconf(_SC_CLK_TCK)

            nsPerSchedulerTick = 1_000_000_000 / schedulerTicksPerSecond
        }

        #if os(macOS)
            fileprivate
            func getProcInfo() -> proc_taskinfo {
                var procTaskInfo = proc_taskinfo()
                let procTaskInfoSize = MemoryLayout<proc_taskinfo>.size

                let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &procTaskInfo, Int32(procTaskInfoSize))

                if result != procTaskInfoSize {
                    fatalError("proc_pidinfo returned an error \(errno)")
                }
                return procTaskInfo
            }

            struct IOStats {
                var bytesRead: UInt64 = 0
                var bytesWritten: UInt64 = 0
            }

            private func getIOStats() -> IOStats {
                var rinfo = rusage_info_v6()
                let result = withUnsafeMutablePointer(to: &rinfo) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                        proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                    }
                }
                if result != 0 {
                    fatalError("proc_pid_rusage returned an error \(errno)")
                }
                return .init(bytesRead: rinfo.ri_diskio_bytesread, bytesWritten: rinfo.ri_diskio_byteswritten)
            }
        #endif

        func startSampling(_: Int = 10_000) { // sample rate in microseconds
            #if os(macOS)
                DispatchQueue.global(qos: .userInitiated).async {
                    self.lock.lock()
                    let rate = self.sampleRate
                    self.peakThreads = 0
                    self.peakThreadsRunning = 0
                    self.runState = .running
                    self.lock.unlock()

                    while true {
                        let procTaskInfo = self.getProcInfo()

                        self.lock.lock()
                        if procTaskInfo.pti_threadnum > self.peakThreads {
                            self.peakThreads = Int(procTaskInfo.pti_threadnum)
                        }

                        if procTaskInfo.pti_numrunning > self.peakThreadsRunning {
                            self.peakThreadsRunning = Int(procTaskInfo.pti_numrunning)
                        }

                        if self.runState == .shuttingDown {
                            self.runState = .done
                            self.semaphore.signal()
                        }

                        let quit = self.runState
                        self.lock.unlock()

                        if quit == .done {
                            return
                        }

                        usleep(UInt32.random(in: UInt32(Double(rate) * 0.9) ... UInt32(Double(rate) * 1.1)))
                    }
                }
                // We'll sleep just a little bit to let the sampler thread get going so we don't get 0 samples
                usleep(1_000)
            #endif
        }

        func stopSampling() {
            #if os(macOS)
                lock.withLock {
                    runState = .shuttingDown
                }
                semaphore.wait()
            #endif
        }

        func configureMetrics(_ metrics: Set<BenchmarkMetric>) {
            self.metrics = metrics
        }

        func makeOperatingSystemStats() -> OperatingSystemStats {
            #if os(macOS)
                guard let metrics else {
                    return .init()
                }

                let procTaskInfo = getProcInfo()
                let userTime = Int(nsPerMachTick * Double(procTaskInfo.pti_total_user))
                let systemTime = Int(nsPerMachTick * Double(procTaskInfo.pti_total_system))
                let totalTime = userTime + systemTime
                var threads = 0
                var threadsRunning = 0

                if metrics.contains(.threads) || metrics.contains(.threadsRunning) {
                    lock.lock()
                    threads = peakThreads
                    threadsRunning = peakThreadsRunning
                    lock.unlock()
                }
                var ioStats = IOStats()

                if metrics.contains(.writeBytesPhysical) || metrics.contains(.writeBytesPhysical) {
                    ioStats = getIOStats()
                }

                let stats = OperatingSystemStats(cpuUser: userTime,
                                                 cpuSystem: systemTime,
                                                 cpuTotal: totalTime,
                                                 peakMemoryResident: Int(procTaskInfo.pti_resident_size),
                                                 peakMemoryVirtual: Int(procTaskInfo.pti_virtual_size),
                                                 syscalls: Int(procTaskInfo.pti_syscalls_unix) +
                                                     Int(procTaskInfo.pti_syscalls_mach),
                                                 contextSwitches: Int(procTaskInfo.pti_csw),
                                                 threads: threads,
                                                 threadsRunning: threadsRunning,
                                                 readSyscalls: 0,
                                                 writeSyscalls: 0,
                                                 readBytesLogical: 0,
                                                 writeBytesLogical: 0,
                                                 readBytesPhysical: Int(ioStats.bytesRead),
                                                 writeBytesPhysical: Int(ioStats.bytesWritten))

                return stats
            #else
                return .init()
            #endif
        }

        func metricSupported(_ metric: BenchmarkMetric) -> Bool {
            #if os(macOS)
                switch metric {
                case .readSyscalls:
                    return false
                case .writeSyscalls:
                    return false
                case .readBytesLogical:
                    return false
                case .writeBytesLogical:
                    return false
                default:
                    return true
                }
            #else
                // No metrics supported due to lack of libproc.h
                return false
            #endif
        }
    }

#endif
