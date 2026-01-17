import Foundation
import HealthKit

extension HealthBgSyncPlugin {

    // MARK: - Public API (called from your anchored queries)
    // Builds payload in the SAME shape as your Flutter-side export:
    // {
    //   "data": {
    //     "records": [ ... _mapRecord(...) or _mapWorkout(...) ... ]
    //   }
    // }
    internal func serialize(samples: [HKSample], type: HKSampleType) -> [String: Any] {
        var records: [[String: Any]] = []

        for s in samples {
            if let w = s as? HKWorkout {
                records.append(_mapWorkout(w))
            } else if let q = s as? HKQuantitySample {
                records.append(_mapQuantity(q))
            } else if let c = s as? HKCategorySample {
                records.append(_mapCategory(c))
            } else if let corr = s as? HKCorrelation {
                // Optional: flatten correlations (e.g., blood pressure S/D)
                records.append(contentsOf: _mapCorrelation(corr))
            } else {
                // Fallback (unknown type) – keep a minimal shape
                records.append([
                    "uuid": s.uuid.uuidString,
                    "type": s.sampleType.identifier,
                    "value": NSNull(),
                    "unit": NSNull(),
                    "startDate": ISO8601DateFormatter().string(from: s.startDate),
                    "endDate": ISO8601DateFormatter().string(from: s.endDate),
                    "sourceName": s.sourceRevision.source.name,
                    "recordMetadata": _metadataList(s.metadata)
                ])
            }
        }

        return [
            "data": [
                "records": records
            ]
        ]
    }
    
    // MARK: - Memory-efficient streaming serialization
    /// Serializes samples with autoreleasepool to prevent memory buildup
    internal func serializeCombinedStreaming(samples: [HKSample]) -> [String: Any] {
        var workouts: [[String: Any]] = []
        var records: [[String: Any]] = []
        
        // Reuse date formatter to avoid repeated allocations
        let dateFormatter = ISO8601DateFormatter()
        
        // Process in batches with autoreleasepool to release intermediate objects
        let batchSize = 100
        for batchStart in stride(from: 0, to: samples.count, by: batchSize) {
            autoreleasepool {
                let batchEnd = min(batchStart + batchSize, samples.count)
                let batch = samples[batchStart..<batchEnd]
                
                for s in batch {
                    if let w = s as? HKWorkout {
                        workouts.append(_mapWorkoutEfficient(w, dateFormatter: dateFormatter))
                    } else if let q = s as? HKQuantitySample {
                        records.append(_mapQuantityEfficient(q, dateFormatter: dateFormatter))
                    } else if let c = s as? HKCategorySample {
                        records.append(_mapCategoryEfficient(c, dateFormatter: dateFormatter))
                    } else if let corr = s as? HKCorrelation {
                        records.append(contentsOf: _mapCorrelationEfficient(corr, dateFormatter: dateFormatter))
                    } else {
                        records.append([
                            "uuid": s.uuid.uuidString,
                            "type": s.sampleType.identifier,
                            "value": NSNull(),
                            "unit": NSNull(),
                            "startDate": dateFormatter.string(from: s.startDate),
                            "endDate": dateFormatter.string(from: s.endDate),
                            "sourceName": s.sourceRevision.source.name,
                            "recordMetadata": _metadataList(s.metadata)
                        ])
                    }
                }
            }
        }
        
        return [
            "data": [
                "workouts": workouts,
                "records": records
            ]
        ]
    }
    
    // MARK: - Combined serialization for all data types (legacy)
    internal func serializeCombined(samples: [HKSample], anchors: [String: HKQueryAnchor]) -> [String: Any] {
        var workouts: [[String: Any]] = []
        var records: [[String: Any]] = []
        
        for s in samples {
            if let w = s as? HKWorkout {
                // Separate workouts into their own array
                workouts.append(_mapWorkout(w))
            } else if let q = s as? HKQuantitySample {
                records.append(_mapQuantity(q))
            } else if let c = s as? HKCategorySample {
                records.append(_mapCategory(c))
            } else if let corr = s as? HKCorrelation {
                // Optional: flatten correlations (e.g., blood pressure S/D)
                records.append(contentsOf: _mapCorrelation(corr))
            } else {
                // Fallback (unknown type) – keep a minimal shape
                records.append([
                    "uuid": s.uuid.uuidString,
                    "type": s.sampleType.identifier,
                    "value": NSNull(),
                    "unit": NSNull(),
                    "startDate": ISO8601DateFormatter().string(from: s.startDate),
                    "endDate": ISO8601DateFormatter().string(from: s.endDate),
                    "sourceName": s.sourceRevision.source.name,
                    "recordMetadata": _metadataList(s.metadata)
                ])
            }
        }
        
        return [
            "data": [
                "workouts": workouts,
                "records": records
            ]
        ]
    }

    // MARK: - Type mapping (supports a wide set of HealthKit types)
    // The input strings MUST match the Dart enum identifiers below.
    internal func mapTypes(_ names: [String]) -> [HKSampleType] {
        var out: [HKSampleType] = []
        for n in names {
            switch n {

            // Activity / movement
            case "steps":
                if let t = HKObjectType.quantityType(forIdentifier: .stepCount) { out.append(t) }
            case "distanceWalkingRunning":
                if let t = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) { out.append(t) }
            case "distanceCycling":
                if let t = HKObjectType.quantityType(forIdentifier: .distanceCycling) { out.append(t) }
            case "flightsClimbed":
                if let t = HKObjectType.quantityType(forIdentifier: .flightsClimbed) { out.append(t) }
            case "walkingSpeed":
                if let t = HKObjectType.quantityType(forIdentifier: .walkingSpeed) { out.append(t) }
            case "walkingStepLength":
                if let t = HKObjectType.quantityType(forIdentifier: .walkingStepLength) { out.append(t) }
            case "walkingAsymmetryPercentage":
                if let t = HKObjectType.quantityType(forIdentifier: .walkingAsymmetryPercentage) { out.append(t) }
            case "walkingDoubleSupportPercentage":
                if let t = HKObjectType.quantityType(forIdentifier: .walkingDoubleSupportPercentage) { out.append(t) }
            case "sixMinuteWalkTestDistance":
                if let t = HKObjectType.quantityType(forIdentifier: .sixMinuteWalkTestDistance) { out.append(t) }

            // Energy
            case "activeEnergy":
                if let t = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) { out.append(t) }
            case "basalEnergy":
                if let t = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned) { out.append(t) }

            // Heart
            case "heartRate":
                if let t = HKObjectType.quantityType(forIdentifier: .heartRate) { out.append(t) }
            case "restingHeartRate":
                if let t = HKObjectType.quantityType(forIdentifier: .restingHeartRate) { out.append(t) }
            case "heartRateVariabilitySDNN":
                if let t = HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN) { out.append(t) }
            case "vo2Max":
                if let t = HKObjectType.quantityType(forIdentifier: .vo2Max) { out.append(t) }
            case "oxygenSaturation":
                if let t = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) { out.append(t) }

            // Respiratory
            case "respiratoryRate":
                if let t = HKObjectType.quantityType(forIdentifier: .respiratoryRate) { out.append(t) }

            // Body
            case "bodyMass":
                if let t = HKObjectType.quantityType(forIdentifier: .bodyMass) { out.append(t) }
            case "height":
                if let t = HKObjectType.quantityType(forIdentifier: .height) { out.append(t) }
            case "bmi":
                if let t = HKObjectType.quantityType(forIdentifier: .bodyMassIndex) { out.append(t) }
            case "bodyFatPercentage":
                if let t = HKObjectType.quantityType(forIdentifier: .bodyFatPercentage) { out.append(t) }
            case "leanBodyMass":
                if let t = HKObjectType.quantityType(forIdentifier: .leanBodyMass) { out.append(t) }
            case "waistCircumference":
                if #available(iOS 16.0, *), let t = HKObjectType.quantityType(forIdentifier: .waistCircumference) { out.append(t) }
            case "bodyTemperature":
                if let t = HKObjectType.quantityType(forIdentifier: .bodyTemperature) { out.append(t) }

            // Glucose / insulin
            case "bloodGlucose":
                if let t = HKObjectType.quantityType(forIdentifier: .bloodGlucose) { out.append(t) }
            case "insulinDelivery":
                if #available(iOS 16.0, *), let t = HKObjectType.quantityType(forIdentifier: .insulinDelivery) { out.append(t) }

            // Blood pressure (correlation or separate S/D)
            case "bloodPressureSystolic":
                if let t = HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic) { out.append(t) }
            case "bloodPressureDiastolic":
                if let t = HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic) { out.append(t) }
            case "bloodPressure": // correlation (both S & D)
                if let t = HKObjectType.correlationType(forIdentifier: .bloodPressure) { out.append(t) }

            // Other labs
            case "restingEnergy":
                if let t = HKObjectType.quantityType(forIdentifier: .basalEnergyBurned) { out.append(t) }
            case "bloodOxygen":
                if let t = HKObjectType.quantityType(forIdentifier: .oxygenSaturation) { out.append(t) }

            // Sleep / mindfulness
            case "sleep":
                if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { out.append(t) }
            case "mindfulSession":
                if let t = HKObjectType.categoryType(forIdentifier: .mindfulSession) { out.append(t) }

            // Reproductive (examples)
            case "menstrualFlow":
                if let t = HKObjectType.categoryType(forIdentifier: .menstrualFlow) { out.append(t) }
            case "cervicalMucusQuality":
                if let t = HKObjectType.categoryType(forIdentifier: .cervicalMucusQuality) { out.append(t) }
            case "ovulationTestResult":
                if let t = HKObjectType.categoryType(forIdentifier: .ovulationTestResult) { out.append(t) }
            case "sexualActivity":
                if let t = HKObjectType.categoryType(forIdentifier: .sexualActivity) { out.append(t) }

            // Nutrition (examples)
            case "dietaryEnergyConsumed":
                if let t = HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed) { out.append(t) }
            case "dietaryCarbohydrates":
                if let t = HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates) { out.append(t) }
            case "dietaryProtein":
                if let t = HKObjectType.quantityType(forIdentifier: .dietaryProtein) { out.append(t) }
            case "dietaryFatTotal":
                if let t = HKObjectType.quantityType(forIdentifier: .dietaryFatTotal) { out.append(t) }
            case "dietaryWater":
                if let t = HKObjectType.quantityType(forIdentifier: .dietaryWater) { out.append(t) }

            // Workouts
            case "workout":
                out.append(HKObjectType.workoutType())

            default:
                break
            }
        }
        return out
    }

    // MARK: - Record mappers (backend shape)

    private func _mapQuantity(_ q: HKQuantitySample) -> [String: Any] {
        let df = ISO8601DateFormatter()
        let (unit, unitOut) = _defaultUnit(for: q.quantityType)
        
        // Safely convert the value, handling incompatible units
        let value: Double
        let finalUnit: String
        
        // Check if the conversion is possible
        if q.quantity.is(compatibleWith: unit) {
            value = q.quantity.doubleValue(for: unit)
            finalUnit = unitOut
        } else {
            // Fallback: try to get a reasonable unit for this quantity type
            let fallbackUnit = _getFallbackUnit(for: q.quantityType)
            value = q.quantity.doubleValue(for: fallbackUnit)
            finalUnit = fallbackUnit.unitString
            print("⚠️ Unit conversion failed for \(q.quantityType.identifier): using fallback unit \(fallbackUnit.unitString)")
        }

        return [
            "uuid": q.uuid.uuidString,
            "type": q.quantityType.identifier,
            "value": value,
            "unit": finalUnit,
            "startDate": df.string(from: q.startDate),
            "endDate": df.string(from: q.endDate),
            "sourceName": q.sourceRevision.source.name,
            "recordMetadata": _metadataList(q.metadata)
        ]
    }

    private func _mapCategory(_ c: HKCategorySample) -> [String: Any] {
        let df = ISO8601DateFormatter()
        return [
            "uuid": c.uuid.uuidString,
            "type": c.categoryType.identifier,
            "value": c.value,         // category int value
            "unit": NSNull(),         // no unit for category
            "startDate": df.string(from: c.startDate),
            "endDate": df.string(from: c.endDate),
            "sourceName": c.sourceRevision.source.name,
            "recordMetadata": _metadataList(c.metadata)
        ]
    }

    private func _mapCorrelation(_ corr: HKCorrelation) -> [[String: Any]] {
        // Example: flatten blood pressure correlation into two records
        var records: [[String: Any]] = []
        let df = ISO8601DateFormatter()
        let src = corr.sourceRevision.source.name

        for sample in corr.objects {
            if let q = sample as? HKQuantitySample {
                let (unit, unitOut) = _defaultUnit(for: q.quantityType)
                let value = q.quantity.doubleValue(for: unit)
                records.append([
                    "uuid": q.uuid.uuidString,
                    "type": q.quantityType.identifier, // systolic / diastolic id
                    "value": value,
                    "unit": unitOut,
                    "startDate": df.string(from: q.startDate),
                    "endDate": df.string(from: q.endDate),
                    "sourceName": src,
                    "recordMetadata": _metadataList(q.metadata)
                ])
            }
        }
        return records
    }

    private func _mapWorkout(_ w: HKWorkout) -> [String: Any] {
        let df = ISO8601DateFormatter()
        
        // Build workout statistics array
        var stats: [[String: Any]] = []
        
        // Duration
        stats.append([
            "type": "duration",
            "value": w.duration,
            "unit": "s"
        ])
        
        if #available(iOS 16.0, *) {
            // iOS 16+ - use statistics(for:) API
            if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
               let energyStats = w.statistics(for: energyType),
               let sum = energyStats.sumQuantity() {
                stats.append([
                    "type": "activeEnergyBurned",
                    "value": sum.doubleValue(for: .kilocalorie()),
                    "unit": "kcal"
                ])
            }
            
            // Distance - try multiple types based on workout
            let distanceTypes: [HKQuantityTypeIdentifier] = [
                .distanceWalkingRunning,
                .distanceCycling,
                .distanceSwimming,
                .distanceDownhillSnowSports
            ]
            for distanceTypeId in distanceTypes {
                if let distType = HKQuantityType.quantityType(forIdentifier: distanceTypeId),
                   let distStats = w.statistics(for: distType),
                   let sum = distStats.sumQuantity() {
                    stats.append([
                        "type": "distance",
                        "value": sum.doubleValue(for: .meter()),
                        "unit": "m"
                    ])
                    break
                }
            }
            
            // Heart rate statistics
            if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
               let hrStats = w.statistics(for: hrType) {
                if let avg = hrStats.averageQuantity() {
                    stats.append([
                        "type": "averageHeartRate",
                        "value": avg.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                        "unit": "bpm"
                    ])
                }
                if let max = hrStats.maximumQuantity() {
                    stats.append([
                        "type": "maxHeartRate",
                        "value": max.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                        "unit": "bpm"
                    ])
                }
            }
            
            // Elevation gain - from metadata
            if let elevationAscended = w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
                stats.append([
                    "type": "elevationGain",
                    "value": elevationAscended.doubleValue(for: .meter()),
                    "unit": "m"
                ])
            }
            
        } else {
            // iOS 15 and earlier - use deprecated properties
            if let energy = w.totalEnergyBurned {
                stats.append([
                    "type": "activeEnergyBurned",
                    "value": energy.doubleValue(for: .kilocalorie()),
                    "unit": "kcal"
                ])
            }
            if let dist = w.totalDistance {
                stats.append([
                    "type": "distance",
                    "value": dist.doubleValue(for: .meter()),
                    "unit": "m"
                ])
            }
        }

        return [
            "uuid": w.uuid.uuidString,
            "type": _workoutTypeString(w.workoutActivityType),
            "startDate": df.string(from: w.startDate),
            "endDate": df.string(from: w.endDate),
            "sourceName": w.sourceRevision.source.name,
            "workoutStatistics": stats
        ]
    }

    // MARK: - Units / helpers

    private func _getFallbackUnit(for qt: HKQuantityType) -> HKUnit {
        // For unknown types, try to create a unit from the identifier or use a safe default
        switch qt {
        case HKObjectType.quantityType(forIdentifier: .stepCount):
            return .count()
        case HKObjectType.quantityType(forIdentifier: .heartRate),
             HKObjectType.quantityType(forIdentifier: .restingHeartRate):
            return .count().unitDivided(by: .minute())
        case HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
             HKObjectType.quantityType(forIdentifier: .distanceCycling):
            return .meter()
        case HKObjectType.quantityType(forIdentifier: .bodyMass),
             HKObjectType.quantityType(forIdentifier: .height):
            return .meter()
        case HKObjectType.quantityType(forIdentifier: .bodyTemperature):
            return .degreeCelsius()
        case HKObjectType.quantityType(forIdentifier: .oxygenSaturation):
            return HKUnit.percent()
        case HKObjectType.quantityType(forIdentifier: .bloodGlucose):
            return HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))
        case HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
             HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic):
            return HKUnit.millimeterOfMercury()
        default:
            // For truly unknown types, use count as a safe fallback
            return .count()
        }
    }

    private func _defaultUnit(for qt: HKQuantityType) -> (HKUnit, String) {
        // Choose a sensible unit, and return simplified unit string like your Dart mapper.
        switch qt {
        case HKObjectType.quantityType(forIdentifier: .stepCount):
            return (.count(), "count")
        case HKObjectType.quantityType(forIdentifier: .heartRate):
            return (.count().unitDivided(by: .minute()), "bpm")
        case HKObjectType.quantityType(forIdentifier: .restingHeartRate):
            return (.count().unitDivided(by: .minute()), "bpm")
        case HKObjectType.quantityType(forIdentifier: .heartRateVariabilitySDNN):
            return (.secondUnit(with: .milli), "ms")
        case HKObjectType.quantityType(forIdentifier: .basalEnergyBurned),
             HKObjectType.quantityType(forIdentifier: .activeEnergyBurned),
             HKObjectType.quantityType(forIdentifier: .dietaryEnergyConsumed):
            return (.kilocalorie(), "Cal")
        case HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning),
             HKObjectType.quantityType(forIdentifier: .distanceCycling):
            return (.meter(), "m")
        case HKObjectType.quantityType(forIdentifier: .walkingSpeed):
            return (.meter().unitDivided(by: .second()), "m/s")
        case HKObjectType.quantityType(forIdentifier: .walkingStepLength):
            return (.meter(), "m")
        case HKObjectType.quantityType(forIdentifier: .walkingAsymmetryPercentage):
            return (HKUnit.percent(), "%")
        case HKObjectType.quantityType(forIdentifier: .walkingDoubleSupportPercentage):
            return (HKUnit.percent(), "%")
        case HKObjectType.quantityType(forIdentifier: .sixMinuteWalkTestDistance):
            return (.meter(), "m")
        case HKObjectType.quantityType(forIdentifier: .bodyMass):
            return (.gramUnit(with: .kilo), "kg")
        case HKObjectType.quantityType(forIdentifier: .height):
            return (.meter(), "m")
        case HKObjectType.quantityType(forIdentifier: .bodyMassIndex):
            // BMI is dimensionless (count), but historically expressed as kg/m²
            let bmiUnit = HKUnit.gramUnit(with: .kilo).unitDivided(by: HKUnit.meter().unitMultiplied(by: HKUnit.meter()))
            return (bmiUnit, "kg/m²")
        case HKObjectType.quantityType(forIdentifier: .bodyFatPercentage):
            return (HKUnit.percent(), "%")
        case HKObjectType.quantityType(forIdentifier: .leanBodyMass):
            return (.gramUnit(with: .kilo), "kg")
        case HKObjectType.quantityType(forIdentifier: .waistCircumference):
            return (.meter(), "m")
        case HKObjectType.quantityType(forIdentifier: .bodyTemperature):
            return (.degreeCelsius(), "degC")
        case HKObjectType.quantityType(forIdentifier: .oxygenSaturation):
            return (HKUnit.percent(), "%")
        case HKObjectType.quantityType(forIdentifier: .respiratoryRate):
            return (.count().unitDivided(by: .minute()), "breaths/min")
        case HKObjectType.quantityType(forIdentifier: .bloodGlucose):
            let glucoseUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: HKUnit.literUnit(with: .deci))
            return (glucoseUnit, "mg/dL")
        case HKObjectType.quantityType(forIdentifier: .insulinDelivery):
            return (HKUnit.internationalUnit(), "IU")
        case HKObjectType.quantityType(forIdentifier: .bloodPressureSystolic),
             HKObjectType.quantityType(forIdentifier: .bloodPressureDiastolic):
            return (HKUnit.millimeterOfMercury(), "mmHg")
        case HKObjectType.quantityType(forIdentifier: .vo2Max):
            // Use programmatic API to avoid string parsing issues
            let vo2Unit = HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo)).unitDivided(by: HKUnit.minute())
            return (vo2Unit, "mL/kg/min")
        case HKObjectType.quantityType(forIdentifier: .flightsClimbed):
            return (.count(), "count")
        case HKObjectType.quantityType(forIdentifier: .dietaryCarbohydrates),
             HKObjectType.quantityType(forIdentifier: .dietaryProtein),
             HKObjectType.quantityType(forIdentifier: .dietaryFatTotal):
            return (.gram(), "g")
        case HKObjectType.quantityType(forIdentifier: .dietaryWater):
            return (.liter(), "L")
        default:
            // For unknown types, use count as a safe fallback to avoid crashes
            // HKUnit(from:) will throw an exception if given an invalid unit string
            print("⚠️ Unknown quantity type: \(qt.identifier), using count as fallback")
            return (.count(), "count")
        }
    }

    private func _workoutTypeString(_ t: HKWorkoutActivityType) -> String {
        switch t {
        // Running & Walking
        case .running: return "running"
        case .walking: return "walking"
        case .hiking: return "hiking"
        case .wheelchairRunPace: return "wheelchair_run"
        case .wheelchairWalkPace: return "wheelchair_walk"
        
        // Cycling
        case .cycling: return "cycling"
        case .handCycling: return "hand_cycling"
        
        // Swimming
        case .swimming: return "swimming"
        case .paddleSports: return "paddle_sports"
        case .rowing: return "rowing"
        case .surfingSports: return "surfing"
        case .waterFitness: return "water_fitness"
        case .waterPolo: return "water_polo"
        case .waterSports: return "water_sports"
        
        // Gym & Fitness
        case .traditionalStrengthTraining: return "strength_training"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .coreTraining: return "core_training"
        case .crossTraining: return "cross_training"
        case .mixedCardio: return "mixed_cardio"
        case .highIntensityIntervalTraining: return "hiit"
        case .flexibility: return "flexibility"
        case .cooldown: return "cooldown"
        case .elliptical: return "elliptical"
        case .stairClimbing: return "stair_climbing"
        case .stairs: return "stairs"
        case .stepTraining: return "step_training"
        case .fitnessGaming: return "fitness_gaming"
        case .jumpRope: return "jump_rope"
        case .pilates: return "pilates"
        case .preparationAndRecovery: return "preparation_and_recovery"
        
        // Mind & Body
        case .yoga: return "yoga"
        case .mindAndBody: return "mind_and_body"
        case .barre: return "barre"
        case .taiChi: return "tai_chi"
        
        // Dance
        case .dance: return "dance"
        case .danceInspiredTraining: return "dance_inspired_training"
        case .socialDance: return "social_dance"
        case .cardioDance: return "cardio_dance"
        
        // Racket Sports
        case .tennis: return "tennis"
        case .tableTennis: return "table_tennis"
        case .badminton: return "badminton"
        case .squash: return "squash"
        case .racquetball: return "racquetball"
        case .pickleball: return "pickleball"
        
        // Team Sports
        case .soccer: return "soccer"
        case .basketball: return "basketball"
        case .baseball: return "baseball"
        case .softball: return "softball"
        case .americanFootball: return "american_football"
        case .australianFootball: return "australian_football"
        case .rugby: return "rugby"
        case .hockey: return "hockey"
        case .lacrosse: return "lacrosse"
        case .volleyball: return "volleyball"
        case .handball: return "handball"
        case .cricket: return "cricket"
        case .discSports: return "disc_sports"
        
        // Combat Sports
        case .boxing: return "boxing"
        case .kickboxing: return "kickboxing"
        case .martialArts: return "martial_arts"
        case .wrestling: return "wrestling"
        case .fencing: return "fencing"
        
        // Winter Sports
        case .snowSports: return "snow_sports"
        case .crossCountrySkiing: return "cross_country_skiing"
        case .downhillSkiing: return "downhill_skiing"
        case .snowboarding: return "snowboarding"
        case .skatingSports: return "skating"
        case .curling: return "curling"
        
        // Outdoor Activities
        case .golf: return "golf"
        case .archery: return "archery"
        case .fishing: return "fishing"
        case .hunting: return "hunting"
        case .climbing: return "climbing"
        case .equestrianSports: return "equestrian"
        case .play: return "play"
        
        // Track & Field
        case .trackAndField: return "track_and_field"
        
        // Other
        case .other: return "other"
        
        @unknown default: return "other"
        }
    }

    private func _metadataList(_ meta: [String: Any]?) -> [[String: Any]] {
        var list: [[String: Any]] = []
        guard let meta = meta else { return list }
        for (k, v) in meta {
            list.append([
                "key": k,
                "value": "\(v)"
            ])
        }
        return list
    }
    
    // MARK: - Memory-efficient mappers (reuse date formatter)
    
    private func _mapQuantityEfficient(_ q: HKQuantitySample, dateFormatter: ISO8601DateFormatter) -> [String: Any] {
        let (unit, unitOut) = _defaultUnit(for: q.quantityType)
        
        let value: Double
        let finalUnit: String
        
        if q.quantity.is(compatibleWith: unit) {
            value = q.quantity.doubleValue(for: unit)
            finalUnit = unitOut
        } else {
            let fallbackUnit = _getFallbackUnit(for: q.quantityType)
            value = q.quantity.doubleValue(for: fallbackUnit)
            finalUnit = fallbackUnit.unitString
        }

        return [
            "uuid": q.uuid.uuidString,
            "type": q.quantityType.identifier,
            "value": value,
            "unit": finalUnit,
            "startDate": dateFormatter.string(from: q.startDate),
            "endDate": dateFormatter.string(from: q.endDate),
            "sourceName": q.sourceRevision.source.name,
            "recordMetadata": _metadataList(q.metadata)
        ]
    }

    private func _mapCategoryEfficient(_ c: HKCategorySample, dateFormatter: ISO8601DateFormatter) -> [String: Any] {
        return [
            "uuid": c.uuid.uuidString,
            "type": c.categoryType.identifier,
            "value": c.value,
            "unit": NSNull(),
            "startDate": dateFormatter.string(from: c.startDate),
            "endDate": dateFormatter.string(from: c.endDate),
            "sourceName": c.sourceRevision.source.name,
            "recordMetadata": _metadataList(c.metadata)
        ]
    }

    private func _mapCorrelationEfficient(_ corr: HKCorrelation, dateFormatter: ISO8601DateFormatter) -> [[String: Any]] {
        var records: [[String: Any]] = []
        let src = corr.sourceRevision.source.name

        for sample in corr.objects {
            if let q = sample as? HKQuantitySample {
                let (unit, unitOut) = _defaultUnit(for: q.quantityType)
                let value = q.quantity.doubleValue(for: unit)
                records.append([
                    "uuid": q.uuid.uuidString,
                    "type": q.quantityType.identifier,
                    "value": value,
                    "unit": unitOut,
                    "startDate": dateFormatter.string(from: q.startDate),
                    "endDate": dateFormatter.string(from: q.endDate),
                    "sourceName": src,
                    "recordMetadata": _metadataList(q.metadata)
                ])
            }
        }
        return records
    }

    private func _mapWorkoutEfficient(_ w: HKWorkout, dateFormatter: ISO8601DateFormatter) -> [String: Any] {
        var stats: [[String: Any]] = []
        
        stats.append([
            "type": "duration",
            "value": w.duration,
            "unit": "s"
        ])
        
        if #available(iOS 16.0, *) {
            if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
               let energyStats = w.statistics(for: energyType),
               let sum = energyStats.sumQuantity() {
                stats.append([
                    "type": "activeEnergyBurned",
                    "value": sum.doubleValue(for: .kilocalorie()),
                    "unit": "kcal"
                ])
            }
            
            let distanceTypes: [HKQuantityTypeIdentifier] = [
                .distanceWalkingRunning,
                .distanceCycling,
                .distanceSwimming,
                .distanceDownhillSnowSports
            ]
            for distanceTypeId in distanceTypes {
                if let distType = HKQuantityType.quantityType(forIdentifier: distanceTypeId),
                   let distStats = w.statistics(for: distType),
                   let sum = distStats.sumQuantity() {
                    stats.append([
                        "type": "distance",
                        "value": sum.doubleValue(for: .meter()),
                        "unit": "m"
                    ])
                    break
                }
            }
            
            if let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate),
               let hrStats = w.statistics(for: hrType) {
                if let avg = hrStats.averageQuantity() {
                    stats.append([
                        "type": "averageHeartRate",
                        "value": avg.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                        "unit": "bpm"
                    ])
                }
                if let max = hrStats.maximumQuantity() {
                    stats.append([
                        "type": "maxHeartRate",
                        "value": max.doubleValue(for: HKUnit.count().unitDivided(by: .minute())),
                        "unit": "bpm"
                    ])
                }
            }
            
            if let elevationAscended = w.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
                stats.append([
                    "type": "elevationGain",
                    "value": elevationAscended.doubleValue(for: .meter()),
                    "unit": "m"
                ])
            }
            
        } else {
            if let energy = w.totalEnergyBurned {
                stats.append([
                    "type": "activeEnergyBurned",
                    "value": energy.doubleValue(for: .kilocalorie()),
                    "unit": "kcal"
                ])
            }
            if let dist = w.totalDistance {
                stats.append([
                    "type": "distance",
                    "value": dist.doubleValue(for: .meter()),
                    "unit": "m"
                ])
            }
        }

        return [
            "uuid": w.uuid.uuidString,
            "type": _workoutTypeString(w.workoutActivityType),
            "startDate": dateFormatter.string(from: w.startDate),
            "endDate": dateFormatter.string(from: w.endDate),
            "sourceName": w.sourceRevision.source.name,
            "workoutStatistics": stats
        ]
    }
}
