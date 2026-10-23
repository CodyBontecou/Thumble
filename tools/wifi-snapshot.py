# Reads dumpsys wifi on stdin; exports numeric radio counters only, never SSID/BSSID.
import json,re,sys
names=['timestamp_ms','rssi','link_speed_mbps','rx_link_speed_mbps','total_tx_success','total_tx_retries','total_tx_bad','total_rx_success','total_cca_busy_freq_time_ms','total_radio_on_freq_time_ms']
samples=[]
for line in sys.stdin:
 if 'timestamp_ms=' not in line or 'total_cca_busy_freq_time_ms=' not in line:continue
 sample={key:int(value) for key,value in re.findall(r'\b('+ '|'.join(names) +r')=(-?\d+)\b',line)}
 if 'timestamp_ms' in sample:samples.append(sample)
print(json.dumps(max(samples,key=lambda x:x['timestamp_ms']) if samples else {'available':False},indent=2))
