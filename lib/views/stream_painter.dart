import 'dart:async' show Timer;
import 'dart:ui' as ui_para;
import 'package:material_ui/material_ui.dart';
import '../models/data_layer.dart';
import './stream_registry.dart';

class PlotOptions {
  final Color backgroundColor;
  final Color penColor;
  final double penStrokeWidth;

  final Color majorTicksColor;
  final Color minorTicksColor;

  final Duration plotDuration;

  PlotOptions({this.backgroundColor = Colors.white,
               this.penColor = Colors.black,
               this.penStrokeWidth = 1,
               this.majorTicksColor = Colors.black,
               this.minorTicksColor = Colors.black,
               this.plotDuration = const Duration(minutes: 2)});

}

/// Plots one stream.
///
/// Deliberately knows nothing about connections. Packets are pushed to it by
/// whoever owns the connection - see MultiStreamPainter - because getPackets
/// consumes packets from the connection, so a plot that fetched for itself
/// would take data belonging to the other plots.
///
/// With no [identifier] and [registry] it invents its own trace, which is
/// useful for working on the plotting with no server to hand.
class StreamPainter extends StatefulWidget {
  final Color backgroundColor;

  /// The stream this plot is showing.
  final StreamIdentifier? identifier;

  /// Where to register for that stream's packets.
  final StreamRegistry? registry;

  const StreamPainter({
    super.key,
    this.backgroundColor = Colors.white,
    this.identifier,
    this.registry,
  });

  /// True when packets are pushed in rather than invented.
  bool get isLive => identifier != null && registry != null;

  @override
  State createState() => _StreamPainterState();
}

class _StreamPainterState extends State<StreamPainter> {
  static const _redrawInterval = Duration(seconds: 3);

  late PlotOptions mPlotOptions;

  /// The rolling window of samples this plot is drawing.
  late Stream mStream;
  Timer? _redrawTimer;

  @override
  void initState() {
    super.initState();
    mPlotOptions = PlotOptions(backgroundColor: widget.backgroundColor);
    _start();
  }

  @override
  void didUpdateWidget(StreamPainter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identifier?.toString() != widget.identifier?.toString() ||
        oldWidget.registry != widget.registry) {
      _stop(oldWidget);
      _start();
    }
  }

  void _start() {
    final identifier = widget.identifier;
    final registry = widget.registry;
    if (widget.isLive) {
      mStream = Stream(identifier!, <Packet>[]);
      registry!.register(identifier, _onPacket);
      // The plot window is always the last couple of minutes, so it has to be
      // redrawn as time passes even when nothing new has arrived.
      _redrawTimer = Timer.periodic(_redrawInterval, (_) {
        if (mounted) {
          setState(() {});
        }
      });
    } else {
      mStream = createRandomStream();
      _redrawTimer = Timer.periodic(_redrawInterval, (_) {
        final startTimeMuS = DateTime.now().microsecondsSinceEpoch
            - _redrawInterval.inMicroseconds;
        final packet = createNextPacket(startTimeMuS, 100.0,
            _redrawInterval.inMicroseconds);
        if (mounted) {
          setState(() => mStream.addPacket(packet));
        }
      });
    }
  }

  void _stop(StreamPainter configuration) {
    _redrawTimer?.cancel();
    _redrawTimer = null;
    if (configuration.isLive) {
      configuration.registry!.unregister(configuration.identifier!, _onPacket);
    }
  }

  /// A packet arrived for this stream.  Stream.addPacket keeps the rolling
  /// window trimmed, so this does not grow without bound.
  void _onPacket(Packet packet) {
    if (mounted) {
      setState(() => mStream.addPacket(packet));
    }
  }

  @override
  void dispose() {
    _stop(widget);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _StreamPainter(mPlotOptions, mStream),
      size: Size.infinite,
    );
  }
}

class _StreamPainter extends CustomPainter {
  final PlotOptions mPlotOptions;
  final Stream _mStream;
  late DateTime _plotStartTime;
  late DateTime _plotEndTime;
  late int _plotStartTimeInMicroSeconds;
  late int _plotEndTimeInMicroSeconds;
  //late double mInverseSpatialWidth;
  late double mPlotWidth;
  late double _transformSpaceToTimeInMicroseconds;
  late double _transformTimeInMicroSecondsToSpace;
  late double _transformDataToGrid;

  _StreamPainter(this.mPlotOptions, this._mStream);

  /// This is called first and is in the background
  @override 
  void paint(Canvas canvas, Size size) {
    mPlotWidth = (size.width - 1) - 1; // x1 - x0
    //mInverseSpatialWidth = 1;
    _transformSpaceToTimeInMicroseconds = 1;
    if (mPlotWidth > 1) {
      //mInverseSpatialWidth = 1/(mPlotWidth - 2);
      _transformSpaceToTimeInMicroseconds
       = mPlotOptions.plotDuration.inMicroseconds/mPlotWidth;
    }

    //var stream = createRandomStream();

    double height = size.height;
    double width = size.width; 
    int plotWindowMicroSeconds = mPlotOptions.plotDuration.inMicroseconds;
    final endTime = DateTime.now();
    final endTimeMicroSeconds = endTime.microsecondsSinceEpoch;
    _plotStartTimeInMicroSeconds
      = endTimeMicroSeconds - plotWindowMicroSeconds;
    _plotEndTimeInMicroSeconds
      = _plotStartTimeInMicroSeconds + plotWindowMicroSeconds;
    _transformTimeInMicroSecondsToSpace = 1;
    if (mPlotOptions.plotDuration.inMicroseconds > 0) {
      _transformTimeInMicroSecondsToSpace
        = mPlotWidth/mPlotOptions.plotDuration.inMicroseconds;
    }


    _plotStartTime
      = DateTime.fromMicrosecondsSinceEpoch(_plotStartTimeInMicroSeconds);
    _plotEndTime
      = DateTime.fromMicrosecondsSinceEpoch(_plotEndTimeInMicroSeconds);

    var minMaxData
     = _mStream.getMinimumAndMaximumInTimeRange(_plotStartTimeInMicroSeconds,
                                                _plotEndTimeInMicroSeconds);
    print(minMaxData);
    double dataRange = minMaxData.y - minMaxData.x;
    if (dataRange != 0) {
      _transformDataToGrid = height/dataRange;
    }

    // Draw the background
    drawBackground(canvas, width, height, mPlotOptions);

    // Draw the stream name
    drawStreamName(canvas, height, _mStream.streamIdentifier);

    // Draw the ticks
    drawTicksDriver(canvas, width, height);

    // Draw the seismgoram
    drawSeismogram(canvas, width, height);

  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return true;
  }

  void drawMajorTicks(Canvas canvas, double width, double height, int nTicks) {
    drawTicks(canvas, width, height, nTicks, 0.050, 1.00, true);
  }

  void drawMinorTicks(Canvas canvas, double width, double height, int nTicks) {
    drawTicks(canvas, width, height, nTicks, 0.025, 0.75, false);
  }

  void drawTicksDriver(Canvas canvas, double width, double height) {
    int nMajorTicks = 5;
    int nMinorTicks = nMajorTicks*10 - 1;
    drawMinorTicks(canvas, width, height, nMinorTicks);
    drawMajorTicks(canvas, width, height, nMajorTicks);
  }

  int xToTimeInMicroseconds(double x) {
    final x0 = 1;
    double y0 = _plotStartTime.microsecondsSinceEpoch.toDouble();
    int y = (y0 + (x - x0)*_transformSpaceToTimeInMicroseconds).floor();
    return y;
  }

  double timeInMicroSecondsToX(int timeInMicroSeconds) {
    double x0 = 1; // Start plot at 1
    double t0 = _plotStartTimeInMicroSeconds.toDouble();
    double x = (x0 + (timeInMicroSeconds - t0)*_transformTimeInMicroSecondsToSpace);
    return x; 
  }

  void drawTicks(Canvas canvas, double width, double height, 
                 int nTicks, double tickFraction, double strokeWidth,
                 bool addTimeLabel) {
    var tickHeight = height*tickFraction;
    double dx = (width - 1)/(nTicks - 1);
    var ticksPath = Path();
    for (var i = 0; i < nTicks; ++i) {
      double xOffset = (i*dx).floor() + 1;
      ////debugPrint('$xOffset $dx $nTicks $width');
      // Draw top
      ticksPath.moveTo(xOffset, 0);
      ticksPath.lineTo(xOffset, 0 + tickHeight);

      // Draw bottom
      ticksPath.moveTo(xOffset, height);
      ticksPath.lineTo(xOffset, height - tickHeight);

      if (addTimeLabel && i < nTicks - 1) {
        final paragraphConstraints = ui_para.ParagraphConstraints(width: 50);
        final paragraphStyle = ui_para.ParagraphStyle(fontSize: 12, textAlign: TextAlign.left);
        var paragraphBuilder = ui_para.ParagraphBuilder(paragraphStyle);
        paragraphBuilder.pushStyle(ui_para.TextStyle(color: Colors.black));

        var tickTimeInMicroseconds = xToTimeInMicroseconds(xOffset); 
        var tickTime = DateTime.fromMicrosecondsSinceEpoch(tickTimeInMicroseconds);
        int hour = tickTime.hour;
        var sHour = hour.toString();
        if (hour < 10) {
          sHour = '0$hour';
        }
        var minute = tickTime.minute;
        var sMinute = minute.toString();
        if (minute < 10) {
          sMinute = '0$minute';
        }
        var second = tickTime.second;
        var sSecond = second.toString();
        if (second < 10) {
          sSecond = '0$second';
        }
        var label = '$sHour:$sMinute:$sSecond';

        paragraphBuilder.addText(label);
        var paragraph = paragraphBuilder.build(); 
        paragraph.layout(paragraphConstraints);
        canvas.drawParagraph(paragraph, Offset(xOffset, height*0.90)); 
      }
    }
    final tickMarksPaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.black
      ..isAntiAlias = false
      ..strokeWidth = strokeWidth;
    canvas.drawPath(ticksPath, tickMarksPaint);
  }

  void drawBackground(Canvas canvas, double width, double height, PlotOptions plotOptions) {
    /// Draw the background
    final backgroundPaint = Paint()..color = plotOptions.backgroundColor;
    canvas.drawRect(Rect.fromPoints(Offset.zero, Offset(width, height)),
                    backgroundPaint);    
  }

  void drawStreamName(Canvas canvas, double height, StreamIdentifier identifier) {
      var text = identifier.toString();
      //if (text.isEmpty){return;}
      const double xOffset = 10;
      var yOffset = height*0.1;
      final paragraphConstraints = ui_para.ParagraphConstraints(width: 120);
      final paragraphStyle = ui_para.ParagraphStyle(fontSize: 15, textAlign: TextAlign.left);
      var paragraphBuilder = ui_para.ParagraphBuilder(paragraphStyle);
      paragraphBuilder.pushStyle(ui_para.TextStyle(color: Colors.black));
      paragraphBuilder.addText(text);
      var paragraph = paragraphBuilder.build(); 
      paragraph.layout(paragraphConstraints);
      //print(xOffset);
      //print(yOffset);
      canvas.drawParagraph(paragraph, Offset(xOffset, yOffset)); 
  }

  void drawSeismogram(Canvas canvas, double width, double height) {
    for (var packet in _mStream.packets) {
      drawPacket(canvas, width, height, packet);
    }
  }

  void drawPacket(Canvas canvas, double width, double height, Packet packet) {
    var path = Path(); 
    var halfHeight = 0.5*height.toDouble();
    var fillScale = 0.9;
    var transformScalar = fillScale*_transformDataToGrid;
    for (var i = 0; i < packet.data.length - 1; i++) {
      var t0 = packet.startTimeMuS + i*packet.samplingPeriodInMicroSeconds;
      var t1 = t0 + packet.samplingPeriodInMicroSeconds;
      double x0 = timeInMicroSecondsToX(t0); 
      double x1 = timeInMicroSecondsToX(t1);
      double v0 = packet.data[i];
      double v1 = packet.data[i + 1];
      double y0 = halfHeight - v0*transformScalar;
      double y1 = halfHeight - v1*transformScalar;
      //double y0 = 50 - packet.data[i]/2;
      //double y1 = 50 - packet.data[i + 1]/2;
      path.moveTo(x0, y0);
      path.lineTo(x1, y1);
    }
    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = Colors.black
      ..isAntiAlias = true //false
      ..strokeWidth = 1;
    canvas.drawPath(path, linePaint);
  }


}

