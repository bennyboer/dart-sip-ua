import 'dart:async';

import 'constants.dart';
import 'constants.dart' as DartSIP_C;
import 'event_manager/event_manager.dart';
import 'event_manager/internal_events.dart';
import 'grammar.dart';
import 'logger.dart';
import 'name_addr_header.dart';
import 'request_sender.dart';
import 'sip_message.dart';
import 'timers.dart';
import 'transport.dart';
import 'ua.dart';
import 'uri.dart';
import 'utils.dart' as utils;

const int MIN_REGISTER_EXPIRES = 10; // In seconds.

class UnHandledResponse {
  int status_code;
  String reason_phrase;
  UnHandledResponse(this.status_code, this.reason_phrase);
}

class Registrator {
  UA _ua;
  Transport _transport;
  URI _registrar;
  int _expires;
  String _call_id;
  int _cseq;
  URI _to_uri;
  Timer _registrationTimer;
  bool _registering;
  bool _registered;
  String _contact;
  List<String> _extraHeaders;
  String _extraContactParams;

  Registrator(UA ua, [Transport transport]) {
    var reg_id = 1; // Force reg_id to 1.

    _ua = ua;
    _transport = transport;

    _registrar = ua.configuration.registrar_server;
    _expires = ua.configuration.register_expires;

    // Call-ID and CSeq values RFC3261 10.2.
    _call_id = utils.createRandomToken(22);
    _cseq = 0;

    _to_uri = ua.configuration.uri;

    _registrationTimer = null;

    // Ongoing Register request.
    _registering = false;

    // Set status.
    _registered = false;

    // Contact header.
    _contact = _ua.contact.toString();

    // Sip.ice media feature tag (RFC 5768).
    _contact += ';+sip.ice';

    // Custom headers for REGISTER and un-REGISTER.
    _extraHeaders = <String>[];

    // Custom Contact header params for REGISTER and un-REGISTER.
    _extraContactParams = '';

    // Custom Contact URI params for REGISTER and un-REGISTER.
    setExtraContactUriParams(
        ua.configuration.register_extra_contact_uri_params);

    if (reg_id != null) {
      _contact += ';reg-id=${reg_id}';
      _contact +=
          ';+sip.instance="<urn:uuid:${_ua.configuration.instance_id}>"';
    }
  }

  bool get registered => _registered;

  Transport get transport => _transport;

  void setExtraHeaders(List<String> extraHeaders) {
    if (extraHeaders is! List) {
      extraHeaders = <String>[];
    }
    _extraHeaders = extraHeaders;
  }

  void setExtraContactParams(Map<String, dynamic> extraContactParams) {
    if (extraContactParams is! Map) {
      extraContactParams = <String, dynamic>{};
    }

    // Reset it.
    _extraContactParams = '';

    extraContactParams.forEach((param_key, param_value) {
      _extraContactParams += (';${param_key}');
      if (param_value != null) {
        _extraContactParams += ('=$param_value');
      }
    });
  }

  void setExtraContactUriParams(Map<String, dynamic> extraContactUriParams) {
    if (extraContactUriParams is! Map) {
      extraContactUriParams = <String, dynamic>{};
    }

    NameAddrHeader contact = Grammar.parse(_contact, 'Contact')[0]['parsed'];
    contact.uri.clearParams();

    extraContactUriParams.forEach((String param_key, dynamic param_value) {
      contact.uri.setParam(param_key, param_value);
    });

    _contact = contact.toString();
  }

  void register() {
    if (_registering) {
      logger.debug('Register request in progress...');
      return;
    }

    var extraHeaders = List<String>.from(_extraHeaders ?? []);

    extraHeaders
        .add('Contact: ${_contact};expires=${_expires}${_extraContactParams}');
    extraHeaders.add('Expires: ${_expires}');

    logger.warn(_contact);

    var request = OutgoingRequest(
        SipMethod.REGISTER,
        _registrar,
        _ua,
        <String, dynamic>{
          'to_uri': _to_uri,
          'call_id': _call_id,
          'cseq': (_cseq += 1)
        },
        extraHeaders);

    EventManager handlers = EventManager();
    handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout value) {
      _registrationFailure(
          UnHandledResponse(408, DartSIP_C.causes.REQUEST_TIMEOUT),
          DartSIP_C.causes.REQUEST_TIMEOUT);
    });
    handlers.on(EventOnTransportError(), (EventOnTransportError value) {
      _registrationFailure(
          UnHandledResponse(500, DartSIP_C.causes.CONNECTION_ERROR),
          DartSIP_C.causes.CONNECTION_ERROR);
    });
    handlers.on(EventOnAuthenticated(), (EventOnAuthenticated value) {
      _cseq += 1;
    });
    handlers.on(EventOnReceiveResponse(), (EventOnReceiveResponse event) {
      {
        // Discard responses to older REGISTER/un-REGISTER requests.
        if (event.response.cseq != _cseq) {
          return;
        }

        // Clear registration timer.
        if (_registrationTimer != null) {
          clearTimeout(_registrationTimer);
          _registrationTimer = null;
        }

        var status_code = event.response.status_code.toString();

        if (utils.test1XX(status_code)) {
          // Ignore provisional responses.
        } else if (utils.test2XX(status_code)) {
          _registering = false;

          if (!event.response.hasHeader('Contact')) {
            logger.debug(
                'no Contact header in response to REGISTER, response ignored');
            return;
          }

          var contacts = [];
          event.response.headers['Contact'].forEach((item) {
            contacts.add(item['parsed']);
          });
          // Get the Contact pointing to us and update the expires value accordingly.
          var contact = contacts.firstWhere(
              (element) => (element.uri.user == _ua.contact.uri.user));

          if (contact == null) {
            logger.debug('no Contact header pointing to us, response ignored');
            return;
          }

          var expires = contact.getParam('expires');

          if (expires == null && event.response.hasHeader('expires')) {
            expires = event.response.getHeader('expires');
          }

          expires ??= _expires;

          expires = num.tryParse(expires) ?? 0;

          if (expires < MIN_REGISTER_EXPIRES) {
            expires = MIN_REGISTER_EXPIRES;
          }

          // Re-Register or emit an event before the expiration interval has elapsed.
          // For that, decrease the expires value. ie: 3 seconds.
          _registrationTimer = setTimeout(() {
            clearTimeout(_registrationTimer);
            _registrationTimer = null;
            // If there are no listeners for registrationExpiring, reregistration.
            // If there are listeners, var the listening do the register call.
            if (!_ua.hasListeners(EventRegistrationExpiring())) {
              register();
            } else {
              _ua.emit(EventRegistrationExpiring());
            }
          }, (expires * 1000) - 5000);

          // Save gruu values.
          if (contact.hasParam('temp-gruu')) {
            _ua.contact.temp_gruu =
                contact.getParam('temp-gruu').replaceAll('"', '');
          }
          if (contact.hasParam('pub-gruu')) {
            _ua.contact.pub_gruu =
                contact.getParam('pub-gruu').replaceAll('"', '');
          }

          if (!_registered) {
            _registered = true;
            _ua.registered(response: event.response);
          }
        } else
        // Interval too brief RFC3261 10.2.8.
        if (status_code.contains(RegExp(r'^423$'))) {
          if (event.response.hasHeader('min-expires')) {
            // Increase our registration interval to the suggested minimum.
            _expires =
                num.tryParse(event.response.getHeader('min-expires')) ?? 0;

            if (_expires < MIN_REGISTER_EXPIRES)
              _expires = MIN_REGISTER_EXPIRES;

            // Attempt the registration again immediately.
            register();
          } else {
            // This response MUST contain a Min-Expires header field.
            logger.debug(
                '423 response received for REGISTER without Min-Expires');

            _registrationFailure(
                event.response, DartSIP_C.causes.SIP_FAILURE_CODE);
          }
        } else {
          var cause = utils.sipErrorCause(event.response.status_code);
          _registrationFailure(event.response, cause);
        }
      }
    });

    var request_sender = RequestSender(_ua, request, handlers);

    _registering = true;
    request_sender.send();
  }

  void unregister(unregister_all) {
    if (_registered == null) {
      logger.debug('already unregistered');

      return;
    }

    _registered = false;

    // Clear the registration timer.
    if (_registrationTimer != null) {
      clearTimeout(_registrationTimer);
      _registrationTimer = null;
    }

    var extraHeaders = List.from(_extraHeaders ?? []);

    if (unregister_all) {
      extraHeaders.add('Contact: *${_extraContactParams}');
    } else {
      extraHeaders.add('Contact: ${_contact};expires=0${_extraContactParams}');
    }

    extraHeaders.add('Expires: 0');

    var request = OutgoingRequest(
        SipMethod.REGISTER,
        _registrar,
        _ua,
        {'to_uri': _to_uri, 'call_id': _call_id, 'cseq': (_cseq += 1)},
        extraHeaders);

    EventManager handlers = EventManager();
    handlers.on(EventOnRequestTimeout(), (EventOnRequestTimeout value) {
      _unregistered(null, DartSIP_C.causes.REQUEST_TIMEOUT);
    });
    handlers.on(EventOnTransportError(), (EventOnTransportError value) {
      _unregistered(null, DartSIP_C.causes.CONNECTION_ERROR);
    });
    handlers.on(EventOnAuthenticated(), (EventOnAuthenticated response) {
      // Increase the CSeq on authentication.

      _cseq += 1;
    });
    handlers.on(EventOnReceiveResponse(), (EventOnReceiveResponse event) {
      var status_code = event.response.status_code.toString();
      if (utils.test2XX(status_code)) {
        _unregistered(event.response);
      } else if (utils.test1XX(status_code)) {
        // Ignore provisional responses.
      } else {
        var cause = utils.sipErrorCause(event.response.status_code);
        _unregistered(event.response, cause);
      }
    });

    var request_sender = RequestSender(_ua, request, handlers);

    request_sender.send();
  }

  void close() {
    if (_registered) {
      unregister(false);
    }
  }

  void onTransportClosed() {
    _registering = false;
    if (_registrationTimer != null) {
      clearTimeout(_registrationTimer);
      _registrationTimer = null;
    }

    if (_registered) {
      _registered = false;
      _ua.unregistered();
    }
  }

  void _registrationFailure(response, cause) {
    _registering = false;
    _ua.registrationFailed(response: response, cause: cause);

    if (_registered) {
      _registered = false;
      _ua.unregistered(response: response, cause: cause);
    }
  }

  void _unregistered([response, cause]) {
    _registering = false;
    _registered = false;
    _ua.unregistered(response: response, cause: cause);
  }
}
