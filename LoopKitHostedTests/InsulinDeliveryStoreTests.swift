//
//  InsulinDeliveryStoreTests.swift
//  LoopKitHostedTests
//
//  Created by Darin Krauss on 10/22/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import XCTest
import HealthKit
@testable import LoopKit

class InsulinDeliveryStoreTestsBase: PersistenceControllerTestCase {
    internal let entry1 = DoseEntry(type: .basal,
                                    startDate: Date(timeIntervalSinceNow: -.minutes(6)),
                                    endDate: Date(timeIntervalSinceNow: -.minutes(5.5)),
                                    value: 1.8,
                                    unit: .unitsPerHour,
                                    deliveredUnits: 0.015,
                                    syncIdentifier: "4B14522E-A7B5-4E73-B76B-5043CD7176B0",
                                    scheduledBasalRate: nil)
    internal let entry2 = DoseEntry(type: .tempBasal,
                                    startDate: Date(timeIntervalSinceNow: -.minutes(2)),
                                    endDate: Date(timeIntervalSinceNow: -.minutes(1.5)),
                                    value: 2.4,
                                    unit: .unitsPerHour,
                                    deliveredUnits: 0.02,
                                    syncIdentifier: "A1F8E29B-33D6-4B38-B4CD-D84F14744871",
                                    scheduledBasalRate: HKQuantity(unit: .internationalUnitsPerHour, doubleValue: 1.8))
    internal let entry3 = DoseEntry(type: .bolus,
                                    startDate: Date(timeIntervalSinceNow: -.minutes(4)),
                                    endDate: Date(timeIntervalSinceNow: -.minutes(3.5)),
                                    value: 1.0,
                                    unit: .units,
                                    deliveredUnits: 1.0,
                                    syncIdentifier: "1A1D6192-1521-4469-B962-1B82C4534BB1",
                                    scheduledBasalRate: nil)
    internal let device = HKDevice(name: UUID().uuidString,
                                   manufacturer: UUID().uuidString,
                                   model: UUID().uuidString,
                                   hardwareVersion: UUID().uuidString,
                                   firmwareVersion: UUID().uuidString,
                                   softwareVersion: UUID().uuidString,
                                   localIdentifier: UUID().uuidString,
                                   udiDeviceIdentifier: UUID().uuidString)

    var mockHealthStore: HKHealthStoreMock!
    var insulinDeliveryStore: InsulinDeliveryStore!
    var hkSampleStore: HealthKitSampleStore!
    var authorizationStatus: HKAuthorizationStatus = .notDetermined

    override func setUp() {
        super.setUp()

        mockHealthStore = HKHealthStoreMock()

        hkSampleStore = HealthKitSampleStore(healthStore: mockHealthStore, type: HealthKitSampleStore.insulinQuantityType)
        hkSampleStore.observerQueryType = MockHKObserverQuery.self
        hkSampleStore.anchoredObjectQueryType = MockHKAnchoredObjectQuery.self

        mockHealthStore.authorizationStatus = authorizationStatus
        insulinDeliveryStore = InsulinDeliveryStore(healthKitSampleStore: hkSampleStore,
                                                    cacheStore: cacheStore,
                                                    cacheLength: .hours(1),
                                                    provenanceIdentifier: HKSource.default().bundleIdentifier)

        let semaphore = DispatchSemaphore(value: 0)
        cacheStore.onReady { error in
            XCTAssertNil(error)
            semaphore.signal()
        }
        semaphore.wait()
    }

    override func tearDown() {
        let semaphore = DispatchSemaphore(value: 0)
        insulinDeliveryStore.purgeAllDoseEntries(healthKitPredicate: HKQuery.predicateForObjects(from: HKSource.default())) { error in
            XCTAssertNil(error)
            semaphore.signal()
        }
        semaphore.wait()

        insulinDeliveryStore = nil
        mockHealthStore = nil

        super.tearDown()
    }
}

class InsulinDeliveryStoreTestsAuthorized: InsulinDeliveryStoreTestsBase {
    override func setUp() {
        authorizationStatus = .sharingAuthorized
        super.setUp()
    }
    
    func testObserverQueryStartup() {
        // Check that an observer query is registered when authorization is already determined.
        XCTAssertFalse(hkSampleStore.authorizationRequired);

        mockHealthStore.observerQueryStartedExpectation = expectation(description: "observer query started")

        waitForExpectations(timeout: 2)

        XCTAssertNotNil(mockHealthStore.observerQuery)
    }
}

class InsulinDeliveryStoreTests: InsulinDeliveryStoreTestsBase {
    // MARK: - HealthKitSampleStore

    func testHealthKitQueryAnchorPersistence() {

        XCTAssert(hkSampleStore.authorizationRequired);
        XCTAssertNil(hkSampleStore.observerQuery);

        mockHealthStore.observerQueryStartedExpectation = expectation(description: "observer query started")

        mockHealthStore.authorizationStatus = .sharingAuthorized
        hkSampleStore.authorizationIsDetermined()

        waitForExpectations(timeout: 3)

        XCTAssertNotNil(mockHealthStore.observerQuery)

        mockHealthStore.anchorQueryStartedExpectation = expectation(description: "anchored object query started")

        let observerQueryCompletionExpectation = expectation(description: "observer query completion")

        let observerQueryCompletionHandler = {
            observerQueryCompletionExpectation.fulfill()
        }

        let mockObserverQuery = mockHealthStore.observerQuery as! MockHKObserverQuery

        // This simulates a signal marking the arrival of new HK Data.
        mockObserverQuery.updateHandler?(mockObserverQuery, observerQueryCompletionHandler, nil)

        wait(for: [mockHealthStore.anchorQueryStartedExpectation!])

        let currentAnchor = HKQueryAnchor(fromValue: 5)

        let mockAnchoredObjectQuery = mockHealthStore.anchoredObjectQuery as! MockHKAnchoredObjectQuery
        mockAnchoredObjectQuery.resultsHandler?(mockAnchoredObjectQuery, [], [], currentAnchor, nil)

        // Wait for observerQueryCompletionExpectation
        waitForExpectations(timeout: 3)

        XCTAssertNotNil(hkSampleStore.queryAnchor)

        cacheStore.managedObjectContext.performAndWait {}

        // Create a new carb store, and ensure it uses the last query anchor

        let newSampleStore = HealthKitSampleStore(healthStore: mockHealthStore, type: HealthKitSampleStore.insulinQuantityType)
        newSampleStore.observerQueryType = MockHKObserverQuery.self
        newSampleStore.anchoredObjectQueryType = MockHKAnchoredObjectQuery.self

        // Create a new glucose store, and ensure it uses the last query anchor
        let _ = InsulinDeliveryStore(healthKitSampleStore: newSampleStore,
                                     cacheStore: cacheStore,
                                     provenanceIdentifier: HKSource.default().bundleIdentifier)

        mockHealthStore.observerQueryStartedExpectation = expectation(description: "new observer query started")

        mockHealthStore.authorizationStatus = .sharingAuthorized
        newSampleStore.authorizationIsDetermined()

        // Wait for observerQueryCompletionExpectation
        waitForExpectations(timeout: 3)

        mockHealthStore.anchorQueryStartedExpectation = expectation(description: "new anchored object query started")

        let mockObserverQuery2 = mockHealthStore.observerQuery as! MockHKObserverQuery

        // This simulates a signal marking the arrival of new HK Data.
        mockObserverQuery2.updateHandler?(mockObserverQuery2, {}, nil)

        // Wait for anchorQueryStartedExpectation
        waitForExpectations(timeout: 3)

        // Assert new carb store is querying with the last anchor that our HealthKit mock returned
        let mockAnchoredObjectQuery2 = mockHealthStore.anchoredObjectQuery as! MockHKAnchoredObjectQuery
        XCTAssertEqual(currentAnchor, mockAnchoredObjectQuery2.anchor)


        mockAnchoredObjectQuery2.resultsHandler?(mockAnchoredObjectQuery2, [], [], currentAnchor, nil)
    }

    // MARK: - Fetching

    func testGetDoseEntries() async throws {
        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([entry1, entry2, entry3], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        await fulfillment(of: [addDoseEntriesCompletion], timeout: 10)

        var entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].type, self.entry1.type)
        XCTAssertEqual(entries[0].startDate, self.entry1.startDate)
        XCTAssertEqual(entries[0].endDate, self.entry1.endDate)
        XCTAssertEqual(entries[0].value, 0.015)
        XCTAssertEqual(entries[0].unit, .units)
        XCTAssertEqual(entries[0].deliveredUnits, 0.015)
        XCTAssertEqual(entries[0].description, self.entry1.description)
        XCTAssertEqual(entries[0].syncIdentifier, self.entry1.syncIdentifier)
        XCTAssertEqual(entries[0].scheduledBasalRate, self.entry1.scheduledBasalRate)
        XCTAssertEqual(entries[1].type, self.entry3.type)
        XCTAssertEqual(entries[1].startDate, self.entry3.startDate)
        XCTAssertEqual(entries[1].endDate, self.entry3.endDate)
        XCTAssertEqual(entries[1].value, self.entry3.value)
        XCTAssertEqual(entries[1].unit, self.entry3.unit)
        XCTAssertEqual(entries[1].deliveredUnits, self.entry3.deliveredUnits)
        XCTAssertEqual(entries[1].description, self.entry3.description)
        XCTAssertEqual(entries[1].syncIdentifier, self.entry3.syncIdentifier)
        XCTAssertEqual(entries[1].scheduledBasalRate, self.entry3.scheduledBasalRate)
        XCTAssertEqual(entries[2].type, self.entry2.type)
        XCTAssertEqual(entries[2].startDate, self.entry2.startDate)
        XCTAssertEqual(entries[2].endDate, self.entry2.endDate)
        XCTAssertEqual(entries[2].value, self.entry2.value)
        XCTAssertEqual(entries[2].unit, self.entry2.unit)
        XCTAssertEqual(entries[2].deliveredUnits, self.entry2.deliveredUnits)
        XCTAssertEqual(entries[2].description, self.entry2.description)
        XCTAssertEqual(entries[2].syncIdentifier, self.entry2.syncIdentifier)
        XCTAssertEqual(entries[2].scheduledBasalRate, self.entry2.scheduledBasalRate)

        entries = try await insulinDeliveryStore.getDoseEntries(start: Date(timeIntervalSinceNow: -.minutes(3.75)), end: Date(timeIntervalSinceNow: -.minutes(1.75)))
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].type, self.entry3.type)
        XCTAssertEqual(entries[0].startDate, self.entry3.startDate)
        XCTAssertEqual(entries[0].endDate, self.entry3.endDate)
        XCTAssertEqual(entries[0].value, self.entry3.value)
        XCTAssertEqual(entries[0].unit, self.entry3.unit)
        XCTAssertEqual(entries[0].deliveredUnits, self.entry3.deliveredUnits)
        XCTAssertEqual(entries[0].description, self.entry3.description)
        XCTAssertEqual(entries[0].syncIdentifier, self.entry3.syncIdentifier)
        XCTAssertEqual(entries[0].scheduledBasalRate, self.entry3.scheduledBasalRate)
        XCTAssertEqual(entries[1].type, self.entry2.type)
        XCTAssertEqual(entries[1].startDate, self.entry2.startDate)
        XCTAssertEqual(entries[1].endDate, self.entry2.endDate)
        XCTAssertEqual(entries[1].value, self.entry2.value)
        XCTAssertEqual(entries[1].unit, self.entry2.unit)
        XCTAssertEqual(entries[1].deliveredUnits, self.entry2.deliveredUnits)
        XCTAssertEqual(entries[1].description, self.entry2.description)
        XCTAssertEqual(entries[1].syncIdentifier, self.entry2.syncIdentifier)
        XCTAssertEqual(entries[1].scheduledBasalRate, self.entry2.scheduledBasalRate)

        let purgeCachedInsulinDeliveryObjectsCompletion = expectation(description: "purgeCachedInsulinDeliveryObjects")
        insulinDeliveryStore.purgeCachedInsulinDeliveryObjects() { error in
            XCTAssertNil(error)
            purgeCachedInsulinDeliveryObjectsCompletion.fulfill()
        }
        await fulfillment(of: [purgeCachedInsulinDeliveryObjectsCompletion], timeout: 10)

        entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 0)
    }

    func testLastBasalEndDate() {
        let getLastImmutableBasalEndDate1Completion = expectation(description: "getLastImmutableBasalEndDate1")
        insulinDeliveryStore.getLastImmutableBasalEndDate() { lastBasalEndDate in
            XCTAssertNil(lastBasalEndDate)
            getLastImmutableBasalEndDate1Completion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([entry1, entry2, entry3], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let getLastImmutableBasalEndDate2Completion = expectation(description: "getLastImmutableBasalEndDate2")
        insulinDeliveryStore.getLastImmutableBasalEndDate() { lastBasalEndDate in
            XCTAssertEqual(lastBasalEndDate, self.entry2.endDate)
            getLastImmutableBasalEndDate2Completion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let purgeCachedInsulinDeliveryObjectsCompletion = expectation(description: "purgeCachedInsulinDeliveryObjects")
        insulinDeliveryStore.purgeCachedInsulinDeliveryObjects() { error in
            XCTAssertNil(error)
            purgeCachedInsulinDeliveryObjectsCompletion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let getLastImmutableBasalEndDate3Completion = expectation(description: "getLastImmutableBasalEndDate3")
        insulinDeliveryStore.getLastImmutableBasalEndDate() { lastBasalEndDate in
            XCTAssertNil(lastBasalEndDate)
            getLastImmutableBasalEndDate3Completion.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    // MARK: - Modification

    func testAddDoseEntries() async throws {
        let addDoseEntries1Completion = expectation(description: "addDoseEntries1")
        insulinDeliveryStore.addDoseEntries([entry1, entry2, entry3], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntries1Completion.fulfill()
        }
        await fulfillment(of: [addDoseEntries1Completion], timeout: 10)

        var entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].type, self.entry1.type)
        XCTAssertEqual(entries[0].startDate, self.entry1.startDate)
        XCTAssertEqual(entries[0].endDate, self.entry1.endDate)
        XCTAssertEqual(entries[0].value, 0.015)
        XCTAssertEqual(entries[0].unit, .units)
        XCTAssertEqual(entries[0].deliveredUnits, 0.015)
        XCTAssertEqual(entries[0].description, self.entry1.description)
        XCTAssertEqual(entries[0].syncIdentifier, self.entry1.syncIdentifier)
        XCTAssertEqual(entries[0].scheduledBasalRate, self.entry1.scheduledBasalRate)
        XCTAssertEqual(entries[1].type, self.entry3.type)
        XCTAssertEqual(entries[1].startDate, self.entry3.startDate)
        XCTAssertEqual(entries[1].endDate, self.entry3.endDate)
        XCTAssertEqual(entries[1].value, self.entry3.value)
        XCTAssertEqual(entries[1].unit, self.entry3.unit)
        XCTAssertEqual(entries[1].deliveredUnits, self.entry3.deliveredUnits)
        XCTAssertEqual(entries[1].description, self.entry3.description)
        XCTAssertEqual(entries[1].syncIdentifier, self.entry3.syncIdentifier)
        XCTAssertEqual(entries[1].scheduledBasalRate, self.entry3.scheduledBasalRate)
        XCTAssertEqual(entries[2].type, self.entry2.type)
        XCTAssertEqual(entries[2].startDate, self.entry2.startDate)
        XCTAssertEqual(entries[2].endDate, self.entry2.endDate)
        XCTAssertEqual(entries[2].value, self.entry2.value)
        XCTAssertEqual(entries[2].unit, self.entry2.unit)
        XCTAssertEqual(entries[2].deliveredUnits, self.entry2.deliveredUnits)
        XCTAssertEqual(entries[2].description, self.entry2.description)
        XCTAssertEqual(entries[2].syncIdentifier, self.entry2.syncIdentifier)
        XCTAssertEqual(entries[2].scheduledBasalRate, self.entry2.scheduledBasalRate)

        let addDoseEntries2Completion = expectation(description: "addDoseEntries2")
        insulinDeliveryStore.addDoseEntries([entry3, entry1, entry2], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntries2Completion.fulfill()
        }
        await fulfillment(of: [addDoseEntries2Completion], timeout: 10)

        entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].type, self.entry1.type)
        XCTAssertEqual(entries[0].startDate, self.entry1.startDate)
        XCTAssertEqual(entries[0].endDate, self.entry1.endDate)
        XCTAssertEqual(entries[0].value, 0.015)
        XCTAssertEqual(entries[0].unit, .units)
        XCTAssertEqual(entries[0].deliveredUnits, 0.015)
        XCTAssertEqual(entries[0].description, self.entry1.description)
        XCTAssertEqual(entries[0].syncIdentifier, self.entry1.syncIdentifier)
        XCTAssertEqual(entries[0].scheduledBasalRate, self.entry1.scheduledBasalRate)
        XCTAssertEqual(entries[1].type, self.entry3.type)
        XCTAssertEqual(entries[1].startDate, self.entry3.startDate)
        XCTAssertEqual(entries[1].endDate, self.entry3.endDate)
        XCTAssertEqual(entries[1].value, self.entry3.value)
        XCTAssertEqual(entries[1].unit, self.entry3.unit)
        XCTAssertEqual(entries[1].deliveredUnits, self.entry3.deliveredUnits)
        XCTAssertEqual(entries[1].description, self.entry3.description)
        XCTAssertEqual(entries[1].syncIdentifier, self.entry3.syncIdentifier)
        XCTAssertEqual(entries[1].scheduledBasalRate, self.entry3.scheduledBasalRate)
        XCTAssertEqual(entries[2].type, self.entry2.type)
        XCTAssertEqual(entries[2].startDate, self.entry2.startDate)
        XCTAssertEqual(entries[2].endDate, self.entry2.endDate)
        XCTAssertEqual(entries[2].value, self.entry2.value)
        XCTAssertEqual(entries[2].unit, self.entry2.unit)
        XCTAssertEqual(entries[2].deliveredUnits, self.entry2.deliveredUnits)
        XCTAssertEqual(entries[2].description, self.entry2.description)
        XCTAssertEqual(entries[2].syncIdentifier, self.entry2.syncIdentifier)
        XCTAssertEqual(entries[2].scheduledBasalRate, self.entry2.scheduledBasalRate)
    }

    func testAddDoseEntriesEmpty() {
        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    func testAddDoseEntriesNotification() {
        let doseEntriesDidChangeCompletion = expectation(description: "doseEntriesDidChange")
        let observer = NotificationCenter.default.addObserver(forName: InsulinDeliveryStore.doseEntriesDidChange, object: insulinDeliveryStore, queue: nil) { notification in
            doseEntriesDidChangeCompletion.fulfill()
        }

        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([entry1, entry2, entry3], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        wait(for: [doseEntriesDidChangeCompletion, addDoseEntriesCompletion], timeout: 10, enforceOrder: true)

        NotificationCenter.default.removeObserver(observer)
    }

    func testManuallyEnteredDoses() {
        let manualEntry = DoseEntry(type: .bolus,
                                    startDate: Date(timeIntervalSinceNow: -.minutes(15)),
                                    endDate: Date(timeIntervalSinceNow: -.minutes(10)),
                                    value: 3.0,
                                    unit: .units,
                                    deliveredUnits: 3.0,
                                    syncIdentifier: "C0AB1CBD-6B36-4113-9D49-709A022B2451",
                                    manuallyEntered: true)

        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([entry1, manualEntry, entry2, entry3], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let getManuallyEnteredDoses1Completion = expectation(description: "getManuallyEnteredDoses1")
        insulinDeliveryStore.getManuallyEnteredDoses(since: .distantPast) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let entries):
                XCTAssertEqual(entries.count, 1)
                XCTAssertEqual(entries[0], manualEntry)
            }
            getManuallyEnteredDoses1Completion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let getManuallyEnteredDoses2Completion = expectation(description: "getManuallyEnteredDoses2")
        insulinDeliveryStore.getManuallyEnteredDoses(since: Date(timeIntervalSinceNow: -.minutes(12))) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let entries):
                XCTAssertEqual(entries.count, 0)
            }
            getManuallyEnteredDoses2Completion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let deleteAllManuallyEnteredDoses1Completion = expectation(description: "deleteAllManuallyEnteredDoses1")
        insulinDeliveryStore.deleteAllManuallyEnteredDoses(since: Date(timeIntervalSinceNow: -.minutes(12))) { error in
            XCTAssertNil(error)
            deleteAllManuallyEnteredDoses1Completion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let getManuallyEnteredDoses3Completion = expectation(description: "getManuallyEnteredDoses3")
        insulinDeliveryStore.getManuallyEnteredDoses(since: .distantPast) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let entries):
                XCTAssertEqual(entries.count, 1)
                XCTAssertEqual(entries[0], manualEntry)
            }
            getManuallyEnteredDoses3Completion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let deleteAllManuallyEnteredDose2Completion = expectation(description: "deleteAllManuallyEnteredDose2")
        insulinDeliveryStore.deleteAllManuallyEnteredDoses(since: Date(timeIntervalSinceNow: -.minutes(20))) { error in
            XCTAssertNil(error)
            deleteAllManuallyEnteredDose2Completion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let getManuallyEnteredDoses4Completion = expectation(description: "getManuallyEnteredDoses4")
        insulinDeliveryStore.getManuallyEnteredDoses(since: .distantPast) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let entries):
                XCTAssertEqual(entries.count, 0)
            }
            getManuallyEnteredDoses4Completion.fulfill()
        }
        waitForExpectations(timeout: 10)
    }

    // MARK: - Cache Management

    func testEarliestCacheDate() {
        XCTAssertEqual(insulinDeliveryStore.earliestCacheDate.timeIntervalSinceNow, -.hours(1), accuracy: 1)
    }

    func testPurgeAllDoseEntries() async throws {
        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([entry1, entry2, entry3], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        await fulfillment(of: [addDoseEntriesCompletion], timeout: 10)

        var entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 3)

        let purgeAllDoseEntriesCompletion = expectation(description: "purgeAllDoseEntries")
        insulinDeliveryStore.purgeAllDoseEntries(healthKitPredicate: HKQuery.predicateForObjects(from: HKSource.default())) { error in
            XCTAssertNil(error)
            purgeAllDoseEntriesCompletion.fulfill()

        }
        await fulfillment(of: [purgeAllDoseEntriesCompletion], timeout: 10)

        entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 0)
    }

    func testPurgeExpiredGlucoseObjects() async throws {
        let expiredEntry = DoseEntry(type: .bolus,
                                     startDate: Date(timeIntervalSinceNow: -.hours(3)),
                                     endDate: Date(timeIntervalSinceNow: -.hours(2)),
                                     value: 3.0,
                                     unit: .units,
                                     deliveredUnits: nil,
                                     syncIdentifier: "7530B8CA-827A-4DE8-ADE3-9E10FF80A4A9",
                                     scheduledBasalRate: nil)

        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([entry1, entry2, entry3, expiredEntry], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        await fulfillment(of: [addDoseEntriesCompletion], timeout: 10)

        let entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 3)
    }

    func testPurgeCachedInsulinDeliveryObjects() async throws {
        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([entry1, entry2, entry3], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        await fulfillment(of: [addDoseEntriesCompletion], timeout: 10)

        var entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 3)

        let purgeCachedInsulinDeliveryObjects1Completion = expectation(description: "purgeCachedInsulinDeliveryObjects1")
        insulinDeliveryStore.purgeCachedInsulinDeliveryObjects(before: Date(timeIntervalSinceNow: -.minutes(5))) { error in
            XCTAssertNil(error)
            purgeCachedInsulinDeliveryObjects1Completion.fulfill()

        }
        await fulfillment(of: [purgeCachedInsulinDeliveryObjects1Completion], timeout: 10)

        entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 2)

        let purgeCachedInsulinDeliveryObjects2Completion = expectation(description: "purgeCachedInsulinDeliveryObjects2")
        insulinDeliveryStore.purgeCachedInsulinDeliveryObjects() { error in
            XCTAssertNil(error)
            purgeCachedInsulinDeliveryObjects2Completion.fulfill()

        }
        await fulfillment(of: [purgeCachedInsulinDeliveryObjects2Completion], timeout: 10)

        entries = try await insulinDeliveryStore.getDoseEntries()
        XCTAssertEqual(entries.count, 0)
    }

    func testPurgeCachedInsulinDeliveryObjectsNotification() {
        let addDoseEntriesCompletion = expectation(description: "addDoseEntries")
        insulinDeliveryStore.addDoseEntries([entry1, entry2, entry3], from: device, syncVersion: 2) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success:
                break
            }
            addDoseEntriesCompletion.fulfill()
        }
        waitForExpectations(timeout: 10)

        let doseEntriesDidChangeCompletion = expectation(description: "doseEntriesDidChange")
        let observer = NotificationCenter.default.addObserver(forName: InsulinDeliveryStore.doseEntriesDidChange, object: insulinDeliveryStore, queue: nil) { notification in
            doseEntriesDidChangeCompletion.fulfill()
        }

        let purgeCachedInsulinDeliveryObjectsCompletion = expectation(description: "purgeCachedInsulinDeliveryObjects")
        insulinDeliveryStore.purgeCachedInsulinDeliveryObjects() { error in
            XCTAssertNil(error)
            purgeCachedInsulinDeliveryObjectsCompletion.fulfill()

        }
        wait(for: [doseEntriesDidChangeCompletion, purgeCachedInsulinDeliveryObjectsCompletion], timeout: 10, enforceOrder: true)

        NotificationCenter.default.removeObserver(observer)
    }
}

class InsulinDeliveryStoreQueryAnchorTests: XCTestCase {

    var rawValue: InsulinDeliveryStore.QueryAnchor.RawValue = [
        "modificationCounter": Int64(123)
    ]

    func testInitializerDefault() {
        let queryAnchor = InsulinDeliveryStore.QueryAnchor()
        XCTAssertEqual(queryAnchor.modificationCounter, 0)
    }

    func testInitializerRawValue() {
        let queryAnchor = InsulinDeliveryStore.QueryAnchor(rawValue: rawValue)
        XCTAssertNotNil(queryAnchor)
        XCTAssertEqual(queryAnchor?.modificationCounter, 123)
    }

    func testInitializerRawValueMissingModificationCounter() {
        rawValue["modificationCounter"] = nil
        XCTAssertNil(InsulinDeliveryStore.QueryAnchor(rawValue: rawValue))
    }

    func testInitializerRawValueInvalidModificationCounter() {
        rawValue["modificationCounter"] = "123"
        XCTAssertNil(InsulinDeliveryStore.QueryAnchor(rawValue: rawValue))
    }

    func testRawValueWithDefault() {
        let rawValue = InsulinDeliveryStore.QueryAnchor().rawValue
        XCTAssertEqual(rawValue.count, 1)
        XCTAssertEqual(rawValue["modificationCounter"] as? Int64, Int64(0))
    }

    func testRawValueWithNonDefault() {
        var queryAnchor = InsulinDeliveryStore.QueryAnchor()
        queryAnchor.modificationCounter = 123
        let rawValue = queryAnchor.rawValue
        XCTAssertEqual(rawValue.count, 1)
        XCTAssertEqual(rawValue["modificationCounter"] as? Int64, Int64(123))
    }

}

class InsulinDeliveryStoreQueryTests: PersistenceControllerTestCase {

    let insulinModel = WalshInsulinModel(actionDuration: .hours(4))
    let basalProfile = BasalRateSchedule(rawValue: ["timeZone": -28800, "items": [["value": 0.75, "startTime": 0.0], ["value": 0.8, "startTime": 10800.0], ["value": 0.85, "startTime": 32400.0], ["value": 1.0, "startTime": 68400.0]]])
    let insulinSensitivitySchedule = InsulinSensitivitySchedule(rawValue: ["unit": "mg/dL", "timeZone": -28800, "items": [["value": 40.0, "startTime": 0.0], ["value": 35.0, "startTime": 21600.0], ["value": 40.0, "startTime": 57600.0]]])

    var insulinDeliveryStore: InsulinDeliveryStore!
    var completion: XCTestExpectation!
    var queryAnchor: InsulinDeliveryStore.QueryAnchor!
    var limit: Int!

    override func setUp() {
        super.setUp()

        insulinDeliveryStore = InsulinDeliveryStore(cacheStore: cacheStore,
                                                    provenanceIdentifier: HKSource.default().bundleIdentifier)
        completion = expectation(description: "Completion")
        queryAnchor = InsulinDeliveryStore.QueryAnchor()
        limit = Int.max
    }

    override func tearDown() {
        limit = nil
        queryAnchor = nil
        completion = nil
        insulinDeliveryStore = nil

        super.tearDown()
    }

    func testDoseEmptyWithDefaultQueryAnchor() {
        insulinDeliveryStore.executeDoseQuery(fromQueryAnchor: queryAnchor, limit: limit) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let anchor, let created, let deleted):
                XCTAssertEqual(anchor.modificationCounter, 0)
                XCTAssertEqual(created.count, 0)
                XCTAssertEqual(deleted.count, 0)
            }
            self.completion.fulfill()
        }

        wait(for: [completion], timeout: 2, enforceOrder: true)
    }

    func testDoseEmptyWithMissingQueryAnchor() {
        queryAnchor = nil

        insulinDeliveryStore.executeDoseQuery(fromQueryAnchor: queryAnchor, limit: limit) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let anchor, let created, let deleted):
                XCTAssertEqual(anchor.modificationCounter, 0)
                XCTAssertEqual(created.count, 0)
                XCTAssertEqual(deleted.count, 0)
            }
            self.completion.fulfill()
        }

        wait(for: [completion], timeout: 2, enforceOrder: true)
    }

    func testDoseEmptyWithNonDefaultQueryAnchor() {
        queryAnchor.modificationCounter = 1

        insulinDeliveryStore.executeDoseQuery(fromQueryAnchor: queryAnchor, limit: limit) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let anchor, let created, let deleted):
                XCTAssertEqual(anchor.modificationCounter, 1)
                XCTAssertEqual(created.count, 0)
                XCTAssertEqual(deleted.count, 0)
            }
            self.completion.fulfill()
        }

        wait(for: [completion], timeout: 2, enforceOrder: true)
    }

    func testDoseDataWithUnusedQueryAnchor() {
        let doseData = [DoseDatum(), DoseDatum(deleted: true), DoseDatum()]

        addDoseData(doseData)

        insulinDeliveryStore.executeDoseQuery(fromQueryAnchor: queryAnchor, limit: limit) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let anchor, let created, let deleted):
                XCTAssertEqual(anchor.modificationCounter, 3)
                XCTAssertEqual(created.count, 2)
                XCTAssertEqual(deleted.count, 1)
                if created.count >= 2 {
                    XCTAssertEqual(created[0].syncIdentifier, doseData[0].syncIdentifier)
                    XCTAssertEqual(created[1].syncIdentifier, doseData[2].syncIdentifier)
                }
                if deleted.count >= 1 {
                    XCTAssertEqual(deleted[0].syncIdentifier, doseData[1].syncIdentifier)
                }
            }
            self.completion.fulfill()
        }

        wait(for: [completion], timeout: 2, enforceOrder: true)
    }

    func testDoseDataWithStaleQueryAnchor() {
        let doseData = [DoseDatum(), DoseDatum(deleted: true), DoseDatum()]

        addDoseData(doseData)

        queryAnchor.modificationCounter = 2

        insulinDeliveryStore.executeDoseQuery(fromQueryAnchor: queryAnchor, limit: limit) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let anchor, let created, let deleted):
                XCTAssertEqual(anchor.modificationCounter, 3)
                XCTAssertEqual(created.count, 1)
                XCTAssertEqual(deleted.count, 0)
                if created.count >= 1 {
                    XCTAssertEqual(created[0].syncIdentifier, doseData[2].syncIdentifier)
                }
            }
            self.completion.fulfill()
        }

        wait(for: [completion], timeout: 2, enforceOrder: true)
    }

    func testDoseDataWithCurrentQueryAnchor() {
        let doseData = [DoseDatum(), DoseDatum(deleted: true), DoseDatum()]

        addDoseData(doseData)

        queryAnchor.modificationCounter = 3

        insulinDeliveryStore.executeDoseQuery(fromQueryAnchor: queryAnchor, limit: limit) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let anchor, let created, let deleted):
                XCTAssertEqual(anchor.modificationCounter, 3)
                XCTAssertEqual(created.count, 0)
                XCTAssertEqual(deleted.count, 0)
            }
            self.completion.fulfill()
        }

        wait(for: [completion], timeout: 2, enforceOrder: true)
    }

    func testDoseDataWithLimitCoveredByData() {
        let doseData = [DoseDatum(), DoseDatum(deleted: true), DoseDatum()]

        addDoseData(doseData)

        limit = 2

        insulinDeliveryStore.executeDoseQuery(fromQueryAnchor: queryAnchor, limit: limit) { result in
            switch result {
            case .failure(let error):
                XCTFail("Unexpected failure: \(error)")
            case .success(let anchor, let created, let deleted):
                XCTAssertEqual(anchor.modificationCounter, 2)
                XCTAssertEqual(created.count, 1)
                XCTAssertEqual(deleted.count, 1)
                if created.count >= 1 {
                    XCTAssertEqual(created[0].syncIdentifier, doseData[0].syncIdentifier)
                }
                if deleted.count >= 1 {
                    XCTAssertEqual(deleted[0].syncIdentifier, doseData[1].syncIdentifier)
                }
            }
            self.completion.fulfill()
        }

        wait(for: [completion], timeout: 2, enforceOrder: true)
    }

    private func addDoseData(_ doseData: [DoseDatum]) {
        cacheStore.managedObjectContext.performAndWait {
            for doseDatum in doseData {
                let object = CachedInsulinDeliveryObject(context: self.cacheStore.managedObjectContext)
                object.provenanceIdentifier = HKSource.default().bundleIdentifier
                object.hasLoopKitOrigin = true
                object.startDate = Date().addingTimeInterval(-.minutes(15))
                object.endDate = Date().addingTimeInterval(-.minutes(5))
                object.syncIdentifier = doseDatum.syncIdentifier
                object.deliveredUnits = 1.0
                object.programmedUnits = 2.0
                object.reason = .bolus
                object.createdAt = Date()
                object.deletedAt = doseDatum.deleted ? Date() : nil
                object.manuallyEntered = false
                object.isSuspend = false
                
                self.cacheStore.save()
            }
        }
    }

    private struct DoseDatum {
        let syncIdentifier: String
        let deleted: Bool

        init(deleted: Bool = false) {
            self.syncIdentifier = UUID().uuidString
            self.deleted = deleted
        }
    }

}
