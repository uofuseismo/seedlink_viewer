import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:seedlink_viewer/models/packet.dart';
import 'package:seedlink_viewer/models/stream_identifier.dart';

bool match64x2Lists(Float64x2List a, Float64x2List b) {
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i].x != b[i].x){return false;}
    if (a[i].y != b[i].y){return false;}
  }
  return true;
}

void main() {
  group('Stream', () {
    test('Packet', () {
      final int startTimeMuS = 20;
      final double samplingRateHz = 100;
      final data = Float64List.fromList([-5, 10, 3, -8, 21, -22, 9, 11, 13]);
      final endTimeMuS = startTimeMuS + 10000*(data.length - 1);
      final packet = Packet(startTimeMuS, samplingRateHz, data);
      expect(packet.startTimeMuS, startTimeMuS);
      expect(packet.endTimeMuS, endTimeMuS);
      expect(packet.samplingRateHz, samplingRateHz);
      expect(packet.data.length, 9); //data.length);
      expect(packet.minimumValue, -22);
      expect(packet.maximumValue,  21);
      expect(packet.isNotEmpty(), true); 
      // Evenly divisible - Should be [-5, 10], [-22, 21], [9, 13]
      var refDecimatedData3
        = Float64x2List.fromList( [ Float64x2(-5, 10), 
                                    Float64x2(-22, 21),
                                    Float64x2(9, 13) ]);
      var decimatedData3 = decimateForPlotting(3, packet.data);
      expect(match64x2Lists(decimatedData3, refDecimatedData3), true);
      //var decimatedData3 = decimateForPlotting(3, packet.data); 
      //expect(refDecimatedData3, decimatedData3);
      //print(decimatedData3);
      // Multiple extra -  Should be [-8, 21] and [-22, 13]
      var refDecimatedData5
        = Float64x2List.fromList( [ Float64x2(-8, 21), 
                                    Float64x2(-22, 13) ]);
      var decimatedData5 = decimateForPlotting(5, packet.data);
      expect(match64x2Lists(decimatedData5, refDecimatedData5), true);
      //print(decimatedData5);
      // One sample leftover - this is the gnarly case
      // This should be [-8, 10], [-22, 21]
      var refDecimatedData4
        = Float64x2List.fromList( [ Float64x2(-8, 10), 
                                    Float64x2(-22, 21)] );
      var decimatedData4 = decimateForPlotting(4, packet.data);
      expect(match64x2Lists(decimatedData4, refDecimatedData4), true);
      //print(decimatedData4);
    });
    test('StreamIdentifier', () {
      final idLocationCode = StreamIdentifier('uu', ' CwU', ' hh z ', '01');
      expect(idLocationCode.network, 'UU');
      expect(idLocationCode.station, 'CWU');
      expect(idLocationCode.channel, 'HHZ');
      expect(idLocationCode.locationCode, '01');
      expect(idLocationCode.toString(), 'UU.CWU.HHZ.01');

      final idNoLocationCode = StreamIdentifier('PB', 'B205', ' eh z ', '');
      expect(idNoLocationCode.network, 'PB');
      expect(idNoLocationCode.station, 'B205');
      expect(idNoLocationCode.channel, 'EHZ');
      expect(idNoLocationCode.locationCode, '');
      expect(idNoLocationCode.toString(), 'PB.B205.EHZ.--');
    });

    test('StreamIdentifier.fromString', () {
      final id = StreamIdentifier.fromString('UU.ARUT.EHZ.01');
      expect(id.network, 'UU');
      expect(id.station, 'ARUT');
      expect(id.channel, 'EHZ');
      expect(id.locationCode, '01');

      // -- is how getStreams writes an absent location code
      final idBlankLocationCode = StreamIdentifier.fromString('PB.B205.EHZ.--');
      expect(idBlankLocationCode.locationCode, '');
      final idNoLocationCode = StreamIdentifier.fromString('PB.B205.EHZ');
      expect(idNoLocationCode.locationCode, '');

      // Round trips through toString
      for (final name in ['UU.CWU.HHZ.01', 'PB.B205.EHZ.--']) {
        expect(StreamIdentifier.fromString(name).toString(), name);
      }

      expect(
        () => StreamIdentifier.fromString('UU.CWU'),
        throwsFormatException,
      );
      expect(
        () => StreamIdentifier.fromString('UU.CWU.HHZ.01.extra'),
        throwsFormatException,
      );
    });

    test('StreamIdentifier equality', () {
      expect(
        StreamIdentifier.fromString('UU.CWU.HHZ.01'),
        StreamIdentifier('uu', ' CwU', ' hh z ', '01'),
      );
      expect(
        StreamIdentifier.fromString('UU.CWU.HHZ.01'),
        isNot(StreamIdentifier.fromString('UU.CWU.HHN.01')),
      );
      // A stream list leans on this to deduplicate
      expect(
        {
          StreamIdentifier.fromString('UU.CWU.HHZ.01'),
          StreamIdentifier.fromString('UU.CWU.HHZ.01'),
        },
        hasLength(1),
      );
    });
  });
}