//
//  BLEdeviceMonitor.swift
//  BLEdevice
//
//  Created by Ivan Brazhnikov on 04.02.17.
//  Copyright © 2017 Ivan Brazhnikov. All rights reserved.
//

import Foundation
import CoreBluetooth





protocol PeripheralMonitorDelegate: class { 
  func peripheralMonitor(monitor: PeripheralMonitor, didEndScanning error: Error?)
  func peripheralMonitor(monitor: PeripheralMonitor, didUpdateValueForCharacteristic uuid: CBUUID, error: Error?)
  func peripheralMonitor(monitor: PeripheralMonitor, didWriteValueForCharacteristic uuid: CBUUID, error: Error?)
}

func PeripheralMonitorCreate(peripheral: CBPeripheral, configuration: BLEdeviceConfiguration) -> PeripheralMonitor {
  return PeripheralMonitorDefaultImpl(peripheral: peripheral, configuration: configuration)
}


protocol PeripheralMonitor: class {
  init(peripheral: CBPeripheral, configuration: BLEdeviceConfiguration)
  
  @discardableResult
  func scan() -> Bool
  
  var delegate: PeripheralMonitorDelegate? { get set }
  
  var isPrepared : Bool { get }
  var peripheral: CBPeripheral { get }
  func send(data: Data, characteristicUUID uuid: CBUUID) throws
  func readValue(forCharacteristicUUID uuid: CBUUID) throws
  func dropCache()
  
  func retrieveCachedData(forCharacteristicUUID uuid: CBUUID) -> Data?
  func retrieveData(forCharacteristicUUID uuid: CBUUID) throws -> Data?
}


class PeripheralMonitorDefaultImpl: NSObject, PeripheralMonitor, CBPeripheralDelegate {
  
  weak var delegate: PeripheralMonitorDelegate?
  let peripheral: CBPeripheral
  
  private var characteristicReceivedDataCache = [CBUUID : Data]()
  
  private let config: BLEdeviceConfiguration
 
  
  
  required init(peripheral: CBPeripheral, configuration: BLEdeviceConfiguration) {
    self.peripheral = peripheral
    self.config = configuration
    super.init()
    peripheral.delegate = self
  }
  
  
  @discardableResult
  func scan() -> Bool {
    if scan_discoverService() && scan_discoverCharacteristics() && scan_subscribeOnCharacteristic() {
      return true
    }
    return false
  }
  
  
  var isPrepared: Bool {
    return isCharacteristicsSubscribed
  }
  
  
  
  private func discoveredServices(for uuids: Set<CBUUID>) throws -> [CBService] {
    if let services = peripheral.services, nil == services.index(where: {uuids.contains($0.uuid) == false}) {
      let set = Set(services.map { $0.uuid })
      if uuids.isSubset(of: set) {
        return services.filter({uuids.contains($0.uuid)})
      }
    }
    throw BLEerror.serviceNotDiscovered
  }
  
  
  
  
  private func discoveredService(for uuid: CBUUID) throws -> CBService {
    if let services = peripheral.services,
       let serviceIndex = services.index(where: { $0.uuid == uuid }) {
      return services[serviceIndex]
    }
    
    throw BLEerror.serviceNotDiscovered
  }
  
  
  
  
  private func discoveredCharacteristics(for uuids: Set<CBUUID>, serviceUUID: CBUUID) throws -> [CBCharacteristic] {
    let service = try discoveredService(for: serviceUUID)
    
    if let chs = service.characteristics {
      let set = Set(chs.map({$0.uuid}))
      if uuids.isSubset(of: set) {
        return chs.filter({ uuids.contains($0.uuid) })
      }
    }
    
    throw BLEerror.characteristicNotDiscovered
  }
  
  
  
  private func discoveredCharacteristic(for uuid: CBUUID) throws -> CBCharacteristic {
    let serviceUUID = config.serviceUUID(forCharacteristicUUID: uuid)
    let service = try discoveredService(for: serviceUUID)
    
    if let characteristics = service.characteristics,
       let index = characteristics.index(where: { $0.uuid == uuid })
    {
      return characteristics[index]
    }
    
    throw BLEerror.characteristicNotDiscovered
  }
  
 
  
  func send(data: Data, characteristicUUID uuid: CBUUID) throws {
    // FATAL ERROR if not presented in config
    let description = config.characteristicDescription(for: uuid)
    // THROW error if not discovered
    let characteristic = try discoveredCharacteristic(for: uuid)
    // FATAL ERROR if not presented
    guard let writeType = description.writeType else {
      fatalError("Characteristics for write purpose type should has writeType")
    }
    
    peripheral.writeValue(data, for: characteristic, type: writeType)
  }
  
  
  func readValue(forCharacteristicUUID uuid: CBUUID) throws {
    // THROW error if not discovered
    let characteristic = try discoveredCharacteristic(for: uuid)
    peripheral.readValue(for: characteristic)
  }
  
  
  private var isServicesDiscovered : Bool{
   
    var ok = true

    do {
      _ = try discoveredServices(for: Set(config.servicesUUIDs))
    } catch {
      ok = false
    }
    
    return ok
  }
  
  
  
  private var isCharacteristicsDiscovered: Bool {
    var ok = true
    do {
      for s in config.serviceDescriptions {
       _ = try discoveredCharacteristics(for: Set(s.characteristics.map { $0.uuid }), serviceUUID: s.serviceUUID)
      }
    } catch {
      ok = false
    }
    return ok
  }
  
  
  
  
  private var isCharacteristicsSubscribed: Bool {
    var ok = true
    let chs = config.serviceDescriptions.flatMap ({ $0.characteristics }).filter({ $0.notify == true })
    
    do {
      for ch in chs {
        let characteristic = try discoveredCharacteristic(for: ch.uuid)
        if !characteristic.isNotifying {
          ok = false
          break
        }
      }
    } catch {
      ok = false
    }
    
    return ok
  }
  
  
  @discardableResult
  private func scan_discoverService() -> Bool {
    
    let uuids = config.servicesUUIDs
    
    do{
      _ = try discoveredServices(for: Set(uuids))
      return true
    } catch {}
  
    peripheral.discoverServices(uuids)
    return false
  }
  
  
  @discardableResult
  private func scan_discoverCharacteristics() -> Bool {
    let servicesUUIDs = Set(config.servicesUUIDs)
    let services = try! self.discoveredServices(for: servicesUUIDs)
    for service in services {
    
      let characteristicsUUID = config
        .serviceDescription(for:service.uuid)
        .characteristics.map { $0.uuid }
      
      do {
         let _ = try discoveredCharacteristics(for: Set(characteristicsUUID), serviceUUID: service.uuid)
      } catch {
        peripheral.discoverCharacteristics(characteristicsUUID, for: service)
        return false
      }
      
    }
    return true
  }
  
  
  @discardableResult
  private func scan_subscribeOnCharacteristic() -> Bool {
    
    let allNotifiedCharacterisitcs = config.serviceDescriptions
      .flatMap  { $0.characteristics }
      .filter   { $0.notify }
    
    for ch in allNotifiedCharacterisitcs {
      let ch = try! discoveredCharacteristic(for: ch.uuid)
      if !ch.isNotifying {
        peripheral.setNotifyValue(true, for: ch)
        return false
      }
    }
    
    return true
    
  }
  
  
  private func setCache(data: Data?, forCharacteristicWithUUID uuid: CBUUID) {
    characteristicReceivedDataCache[uuid] = data
  }
  
  func dropCache() {
    characteristicReceivedDataCache.removeAll()
  }
  
  func retrieveCachedData(forCharacteristicUUID uuid: CBUUID) -> Data? {
    return characteristicReceivedDataCache[uuid]
  }
  
  func retrieveData(forCharacteristicUUID uuid: CBUUID) throws -> Data? {
    return try discoveredCharacteristic(for: uuid).value
  }
  
  
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    
    /* Error case */
    if let error = error {
      delegate?.peripheralMonitor(monitor: self, didEndScanning: error)
      return
    }
    
    if scan_discoverService() {
      scan_discoverCharacteristics()
    }
    
  }
  
  
  
  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    
    
    /* Error case */
    if let error = error {
      delegate?.peripheralMonitor(monitor: self, didEndScanning: error)
      return
    }
    
    
    if scan_discoverCharacteristics() {
      scan_subscribeOnCharacteristic()
    }
    
  }
  
  
  
  func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
    
    if let error = error {
      delegate?.peripheralMonitor(monitor: self, didEndScanning: error)
      return
    }
    
    if scan_subscribeOnCharacteristic() {
      delegate?.peripheralMonitor(monitor: self, didEndScanning: nil)
    }
    
  }
  
  
  
  
  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    let data = characteristic.value
    characteristicReceivedDataCache[characteristic.uuid] = data
    delegate?.peripheralMonitor(monitor: self, didUpdateValueForCharacteristic: characteristic.uuid, error: error)
  }
  
  
  
  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    delegate?.peripheralMonitor(monitor: self, didWriteValueForCharacteristic: characteristic.uuid, error: error)
  }
  
  
  
}