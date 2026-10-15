import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = 'WifiConnect';

/** Milliseconds to wait for a wifiConnectionChange event before retrying/reporting failure. */
const CONNECT_TIMEOUT_MS = 29000;
/** How many extra connect attempts are issued after the first one times out. */
const CONNECT_RETRIES = 0;
/** Milliseconds to wait for a disconnect event after removing the candidate config. */
const DISCONNECT_TIMEOUT_MS = 10000;
/** wifiConnectionChange state meaning "disconnected". */
const WIFI_STATE_DISCONNECTED = 0;
/** wifiConnectionChange state meaning "connected". */
const WIFI_STATE_CONNECTED = 1;
/** BusinessError code: permission verification failed. */
const ERR_PERMISSION_DENIED = 201;
/** BusinessError code: caller is not a system/enterprise app for a restricted API. */
const ERR_APP_NOT_ALLOWED = 202;

/** PluginWifiConnectPlugin **/
export default class PluginWifiConnectPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  /** Candidate config id from the last successful addCandidateConfig, used by the disconnect fallback. */
  private lastNetworkId: number | null = null;
  /** Config of the last connect attempt, cached so disconnect can re-add it after removal. */
  private lastConfig: wifiManager.WifiDeviceConfig | null = null;

  getUniqueClassName(): string {
    return 'PluginWifiConnectPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'plugin_wifi_connect');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    this.log(`onMethodCall ${call.method}`);
    switch (call.method) {
      case 'isWifiEnabled':
        this.guard(result, () => result.success(wifiManager.isWifiActive()));
        break;
      case 'activateWifi':
        this.guardPermission(result, () => {
          wifiManager.enableWifi();
          result.success(null);
        });
        break;
      case 'deactivateWifi':
        this.guardPermission(result, () => {
          wifiManager.disableWifi();
          result.success(null);
        });
        break;
      case 'getSSID':
        this.guard(result, () => result.success(wifiManager.getLinkedInfoSync().ssid));
        break;
      case 'connect': {
        const ssid = call.argument('ssid') as string;
        const config: wifiManager.WifiDeviceConfig = {
          ssid: ssid,
          preSharedKey: '',
          isHiddenSsid: false,
          securityType: wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN,
        };
        this.connect(config, ssid, result);
        break;
      }
      case 'secureConnect': {
        const ssid = call.argument('ssid') as string;
        const config: wifiManager.WifiDeviceConfig = {
          ssid: ssid,
          preSharedKey: call.argument('password') as string,
          isHiddenSsid: call.argument('isHidden') == true,
          securityType: this.securityType(call.argument('isWep') == true, call.argument('isWpa3') == true),
        };
        this.connect(config, ssid, result, call.argument('userAction') == true);
        break;
      }
      case 'prefixConnect':
        this.connectByPrefix(call, result, null);
        break;
      case 'securePrefixConnect': {
        const password = call.argument('password') as string;
        this.connectByPrefix(call, result, (scan: wifiManager.WifiScanInfo): wifiManager.WifiDeviceConfig => {
          return {
            ssid: scan.ssid,
            bssid: scan.bssid,
            preSharedKey: password,
            isHiddenSsid: false,
            securityType: scan.securityType,
          };
        });
        break;
      }
      case 'disconnect':
        this.disconnectNetwork(result);
        break;
      default:
        result.notImplemented();
        break;
    }
  }

  private securityType(isWep: boolean, isWpa3: boolean): wifiManager.WifiSecurityType {
    if (isWep) {
      return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_WEP;
    }
    if (isWpa3) {
      return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_SAE;
    }
    return wifiManager.WifiSecurityType.WIFI_SEC_TYPE_PSK;
  }

  private connectByPrefix(call: MethodCall, result: MethodResult,
    makeConfig: ((scan: wifiManager.WifiScanInfo) => wifiManager.WifiDeviceConfig) | null): void {
    const prefix = call.argument('ssid') as string;
    this.guard(result, () => {
      if (!wifiManager.isWifiActive()) {
        result.success(false);
        return;
      }
      const matches = wifiManager.getScanInfoList()
        .filter((scan) => scan.ssid != null && scan.ssid.startsWith(prefix));
      if (matches.length == 0) {
        result.success(false);
        return;
      }
      // pick the strongest signal, mirroring the android implementation
      matches.sort((a, b) => b.rssi - a.rssi);
      const best = matches[0];
      const config: wifiManager.WifiDeviceConfig = makeConfig != null ? makeConfig(best) : {
        ssid: best.ssid,
        bssid: best.bssid,
        preSharedKey: '',
        isHiddenSsid: false,
        securityType: wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN,
      };
      this.connect(config, best.ssid, result);
    });
  }

  private connect(config: wifiManager.WifiDeviceConfig, ssid: string, result: MethodResult,
    userAction: boolean = false): void {
    this.connectAsync(config, ssid, result, userAction).catch((err: Object) => {
      this.fail(result, err);
    });
  }

  private log(message: string): void {
    hilog.info(0x0000, TAG, '%{public}s', message);
    this.channel?.invokeMethod('log', message);
  }

  /** Mirrors android/ios, which auto-negotiate security: take the real securityType from scan results. */
  private applyScanInfo(config: wifiManager.WifiDeviceConfig, ssid: string): void {
    try {
      const scan = wifiManager.getScanInfoList().find((s) => s.ssid == ssid);
      if (scan == null) {
        this.log(`ssid=${ssid} not in scan results, keep provided securityType`);
        return;
      }
      config.bssid = scan.bssid;
      config.bssidType = wifiManager.DeviceAddressType.REAL_DEVICE_ADDRESS;
      config.securityType = scan.securityType;
      this.log(`scan matched ssid=${ssid} securityType=${scan.securityType} rssi=${scan.rssi}`);
      if (scan.securityType == wifiManager.WifiSecurityType.WIFI_SEC_TYPE_OPEN) {
        config.preSharedKey = '';
      }
    } catch (err) {
      const error = err as BusinessError;
      this.log(`scan failed code=${error.code} message=${error.message ?? ''}, keep provided securityType`);
    }
  }

  private async connectAsync(config: wifiManager.WifiDeviceConfig, ssid: string,
    result: MethodResult, userAction: boolean): Promise<void> {
    this.applyScanInfo(config, ssid);
    this.lastConfig = config;
    if (deviceInfo.sdkApiVersion >= 26) {
      // Camera-style hotspots have no internet: keep the wifi link up without
      // prompting, and let internet traffic fall back to cellular.
      config.showNoInternetDialog = false;
    }
    let settled = false;
    let timer: number | null = null;
    let retriesLeft = CONNECT_RETRIES;
    const onConnectionChange = (state: number): void => {
      if (state != WIFI_STATE_CONNECTED || settled) {
        return;
      }
      try {
        const linkedSsid = wifiManager.getLinkedInfoSync().ssid;
        this.log(`wifiConnectionChange connected, linked ssid=${linkedSsid ?? '<null>'} expect=${ssid}`);
        settled = true;
        if (timer != null) {
          clearTimeout(timer);
          timer = null;
        }
        wifiManager.off('wifiConnectionChange', onConnectionChange);
        // System fell back to another network: the attempt is dead on its side,
        // fail fast instead of waiting out the timeout or retrying.
        result.success(linkedSsid == ssid);
        if (linkedSsid != ssid) {
          this.log(`system connected to ${linkedSsid ?? '<null>'} instead, giving up`);
        }
      } catch (err) {
        // linked info not readable yet; keep waiting until timeout
      }
    };
    const issueConnect = (networkId: number): void => {
      if (userAction) {
        this.log(`connectToCandidateConfigWithUserAction networkId=${networkId}`);
        wifiManager.connectToCandidateConfigWithUserAction(networkId).catch((err: Object) => {
          const error = err as BusinessError;
          this.log(`withUserAction failed code=${error.code} message=${error.message ?? ''}`);
        });
      } else {
        this.log(`connectToCandidateConfig networkId=${networkId}`);
        wifiManager.connectToCandidateConfig(networkId);
      }
      timer = setTimeout(() => {
        if (settled) {
          return;
        }
        if (retriesLeft > 0) {
          retriesLeft--;
          this.log('connect timeout, retrying');
          try {
            issueConnect(networkId);
          } catch (err) {
            if (!settled) {
              settled = true;
              wifiManager.off('wifiConnectionChange', onConnectionChange);
              this.fail(result, err);
            }
          }
          return;
        }
        settled = true;
        this.log(`connect timeout waiting for ssid=${ssid}`);
        wifiManager.off('wifiConnectionChange', onConnectionChange);
        result.success(false);
      }, CONNECT_TIMEOUT_MS);
    };
    try {
      wifiManager.on('wifiConnectionChange', onConnectionChange);
      let networkId = this.findCandidateId(ssid);
      if (networkId == null) {
        networkId = await wifiManager.addCandidateConfig(config);
        this.log(`addCandidateConfig networkId=${networkId}`);
        if (networkId < 0) {
          throw new Error('addCandidateConfig failed');
        }
      } else {
        this.log(`reuse candidate networkId=${networkId}`);
      }
      this.lastNetworkId = networkId;
      issueConnect(networkId);
    } catch (err) {
      if (!settled) {
        settled = true;
        if (timer != null) {
          clearTimeout(timer);
        }
        wifiManager.off('wifiConnectionChange', onConnectionChange);
        this.fail(result, err);
      }
    }
  }

  private disconnectNetwork(result: MethodResult): void {
    this.disconnectAsync(result).catch((err: Object) => {
      this.fail(result, err);
    });
  }

  private async disconnectAsync(result: MethodResult): Promise<void> {
    try {
      // Works for system/enterprise apps, and for regular apps on API <= 14.
      // Non-destructive: the candidate config survives, so later connects can reuse it.
      wifiManager.disconnect();
      this.log('wifiManager.disconnect() succeeded');
      result.success(true);
      return;
    } catch (err) {
      const error = err as BusinessError;
      this.log(`wifiManager.disconnect() failed code=${error.code}, trying candidate removal`);
      if (error.code != ERR_PERMISSION_DENIED && error.code != ERR_APP_NOT_ALLOWED) {
        this.fail(result, err);
        return;
      }
    }
    // Regular apps on API 15+ cannot call disconnect(); fall back to removing the
    // candidate config used for the current connection, which tears it down.
    let networkId = this.lastNetworkId;
    if (networkId == null) {
      // App was restarted since the connect; recover the id from persisted candidates.
      networkId = this.findConnectedCandidateId();
    }
    if (networkId == null) {
      this.log('no candidate config from this app, nothing to remove');
      result.success(false);
      return;
    }
    let settled = false;
    const removedId = networkId;
    const onConnectionChange = (state: number): void => {
      if (state != WIFI_STATE_DISCONNECTED || settled) {
        return;
      }
      settled = true;
      wifiManager.off('wifiConnectionChange', onConnectionChange);
      if (this.lastNetworkId == removedId) {
        this.lastNetworkId = null;
      }
      this.log('disconnected after candidate removal');
      result.success(true);
    };
    const timer = setTimeout(() => {
      if (!settled) {
        settled = true;
        wifiManager.off('wifiConnectionChange', onConnectionChange);
        this.log('disconnect timeout after candidate removal');
        result.success(false);
      }
    }, DISCONNECT_TIMEOUT_MS);
    wifiManager.on('wifiConnectionChange', onConnectionChange);
    try {
      this.log(`removeCandidateConfig networkId=${removedId}`);
      await wifiManager.removeCandidateConfig(removedId);
      await this.restoreCandidate(removedId);
    } catch (err) {
      if (!settled) {
        settled = true;
        clearTimeout(timer);
        wifiManager.off('wifiConnectionChange', onConnectionChange);
        this.fail(result, err);
      }
    }
  }

  /** Re-adds the cached config after a removal-based disconnect, so the next connect can reuse it. */
  private async restoreCandidate(removedId: number): Promise<void> {
    if (this.lastConfig == null) {
      return;
    }
    try {
      const newId = await wifiManager.addCandidateConfig(this.lastConfig);
      if (newId >= 0) {
        this.lastNetworkId = newId;
        this.log(`re-added candidate networkId=${newId} (removed ${removedId})`);
      }
    } catch (err) {
      const error = err as BusinessError;
      this.log(`re-add candidate failed code=${error.code}`);
    }
  }

  /** Finds this app's persisted candidate config for the ssid, if any. */
  private findCandidateId(ssid: string): number | null {
    try {
      const configs = wifiManager.getCandidateConfigs();
      configs.forEach((c, i) => {
        this.log(`candidate[${i}] ssid=${c.ssid} netId=${c.netId ?? '<none>'}`);
      });
      const match = configs.find((c) => c.ssid == ssid && c.netId != null);
      this.log(`findCandidateId ssid=${ssid} candidates=${configs.length} netId=${match?.netId ?? '<none>'}`);
      return match?.netId ?? null;
    } catch (err) {
      const error = err as BusinessError;
      this.log(`findCandidateId failed code=${error.code}`);
      return null;
    }
  }

  /** Finds this app's persisted candidate config matching the current connection, if any. */
  private findConnectedCandidateId(): number | null {
    try {
      const linkedSsid = wifiManager.getLinkedInfoSync().ssid;
      if (linkedSsid == null) {
        return null;
      }
      return this.findCandidateId(linkedSsid);
    } catch (err) {
      return null;
    }
  }

  private guard(result: MethodResult, block: () => void): void {
    try {
      block();
    } catch (err) {
      this.fail(result, err);
    }
  }

  /** Degrades permission failures (201/202) to a false result instead of a PlatformException. */
  private guardPermission(result: MethodResult, block: () => void): void {
    try {
      block();
    } catch (err) {
      const error = err as BusinessError;
      if (error.code == ERR_PERMISSION_DENIED || error.code == ERR_APP_NOT_ALLOWED) {
        result.success(false);
        return;
      }
      this.fail(result, err);
    }
  }

  private fail(result: MethodResult, err: Object): void {
    const error = err as BusinessError;
    const code = error.code != null ? `${error.code}` : 'error';
    this.log(`fail code=${code} message=${error.message ?? 'unknown error'}`);
    result.error(code, error.message ?? 'unknown error', null);
  }
}
