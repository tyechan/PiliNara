/// lavf / mpv stream options applied for proxy vs direct playback.
abstract final class VodLavf {
  static const proxyNetworkTimeout = '60';
  static const directNetworkTimeout = '15';

  static const proxyStream =
      'reconnect=1,reconnect_on_network_error=1,reconnect_streamed=1,'
      'reconnect_delay_max=8,timeout=60000000,rw_timeout=60000000,'
      'http_persistent=1';

  static const directStream =
      'reconnect=1,reconnect_on_network_error=1,reconnect_streamed=1,'
      'reconnect_delay_max=8,timeout=15000000,rw_timeout=15000000,'
      'http_persistent=0';
}
