import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';
import { wifiManager } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** Milliseconds to wait for a wifiConnectionChange event before reporting failure. */
const CONNECT_TIMEOUT_MS = 30000;
/** wifiConnectionChange state meaning "connected". */
const WIFI_STATE_CONNECTED = 1;

/** PluginWifiConnectPlugin **/
export default class PluginWifiConnectPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;

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
    switch (call.method) {
      case 'isWifiEnabled':
        this.guard(result, () => result.success(wifiManager.isWifiActive()));
        break;
      case 'activateWifi':
        this.guard(result, () => {
          wifiManager.enableWifi();
          result.success(null);
        });
        break;
      case 'deactivateWifi':
        this.guard(result, () => {
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
        this.connect(config, ssid, result);
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
        this.guard(result, () => {
          wifiManager.disconnect();
          result.success(true);
        });
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
      const matches = wifiManager.getScanResultsSync()
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

  private connect(config: wifiManager.WifiDeviceConfig, ssid: string, result: MethodResult): void {
    this.connectAsync(config, ssid, result).catch((err: Object) => {
      this.fail(result, err);
    });
  }

  private async connectAsync(config: wifiManager.WifiDeviceConfig, ssid: string,
    result: MethodResult): Promise<void> {
    let settled = false;
    let timer: number | null = null;
    const onConnectionChange = (state: number): void => {
      if (state != WIFI_STATE_CONNECTED || settled) {
        return;
      }
      try {
        if (wifiManager.getLinkedInfoSync().ssid == ssid) {
          settled = true;
          if (timer != null) {
            clearTimeout(timer);
          }
          wifiManager.off('wifiConnectionChange', onConnectionChange);
          result.success(true);
        }
      } catch (err) {
        // linked info not readable yet; keep waiting until timeout
      }
    };
    try {
      timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          wifiManager.off('wifiConnectionChange', onConnectionChange);
          result.success(false);
        }
      }, CONNECT_TIMEOUT_MS);
      wifiManager.on('wifiConnectionChange', onConnectionChange);
      const networkId = await wifiManager.addDeviceConfig(config);
      if (networkId < 0) {
        throw new Error('addDeviceConfig failed');
      }
      wifiManager.connectToCandidateConfig(networkId);
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

  private guard(result: MethodResult, block: () => void): void {
    try {
      block();
    } catch (err) {
      this.fail(result, err);
    }
  }

  private fail(result: MethodResult, err: Object): void {
    const error = err as BusinessError;
    const code = error.code != null ? `${error.code}` : 'error';
    result.error(code, error.message ?? 'unknown error', null);
  }
}
