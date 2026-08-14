import 'dart:math';
import 'dart:typed_data';

/// Defines a data packet.
class Packet {
  final int startTimeMuS;      /// Time of first sample (UTC seconds microseconds since epoch)
  final double samplingRateHz; /// The sampling rate in Hz.
  final Float64List data;  /// The time series data.
  late int endTimeMuS;      /// The end time of the packet.
  late double minimumValue; /// The minimum value of the dataset.
  late double maximumValue; /// The maximum value of the dataset.
  late int samplingPeriodInMicroSeconds; /// Sampling period in microseconds
  Packet(this.startTimeMuS, this.samplingRateHz, this.data) {
    if (samplingRateHz <= 0) {
      throw 'Sampling rate $samplingRateHz must be positive';
    }
    var dtMuS = 1000000 / samplingRateHz;
    samplingPeriodInMicroSeconds = dtMuS.round();
    if (data.isNotEmpty) {
      endTimeMuS = startTimeMuS + samplingPeriodInMicroSeconds * (data.length - 1);
      minimumValue = data.reduce(min);
      maximumValue = data.reduce(max);
      /// absoluteMinimumValue = data.reduce( (absMin, value) => min( absMin, value.abs() ))
      /// absoluteMaximumValue = data.reduce( (absMax, value) => max( absMax, value.abs() ))
      /*
      minimumValue = data[0];
      maximumValue = data[0];
      for (double value in data) {
        minimumValue = min(minimumValue, value);
        maximumValue = max(maximumValue, value);
      }
      */
    }
    else {
      endTimeMuS = startTimeMuS;
      minimumValue = 0;
      maximumValue = 0;
    }
  }

  /// True indicates this has data. 
  bool isNotEmpty() {
    return data.isNotEmpty;
  }

  /// A utility routine to get the minimum and maximum in a time window.
  Float64x2? getMinimumAndMaximumInTimeRange(int t0MuS, int t1MuS) {
    // Sometimes it's too early or too late
    if (t1MuS <= t0MuS) {
      throw 'Start time $t0MuS must be less than end time $t1MuS';
    }
    // This can happen quite a bit with the plot window
    if (t0MuS >= endTimeMuS){return null;}
    if (t1MuS <= startTimeMuS){return null;}
    // This is usually the case
    if (t0MuS <= startTimeMuS && t1MuS >= endTimeMuS) {
      return Float64x2 (minimumValue, maximumValue);
    }
    // Try to estimate the start/end indices.  Usually there's some small roundoff
    // error so try to be generous with extra samples if possible.
    // In this case, we start below the desired start time and count up.
    int iStart = 0;
    if (t0MuS > startTimeMuS) {
      iStart = max( ((t0MuS - startTimeMuS)/samplingPeriodInMicroSeconds).floor() - 2, 0);
      int t0Est = startTimeMuS + iStart*samplingPeriodInMicroSeconds;
      while (t0Est < t0MuS && iStart < data.length) {
        ++iStart;
        t0Est = startTimeMuS + iStart*samplingPeriodInMicroSeconds;
      }
    }
    //print(iStart);
    // Now we start above the desired end time and count down.
    int iEnd = data.length;
    if (t1MuS < endTimeMuS) {
      iEnd = min( ((t1MuS - startTimeMuS)/samplingPeriodInMicroSeconds).ceil() + 2, data.length);
      int t1Est = startTimeMuS + iEnd*samplingPeriodInMicroSeconds;
      while (t1Est > t1MuS && iEnd > iStart) {
        --iEnd;
        t1Est = startTimeMuS + iStart*samplingPeriodInMicroSeconds;
      }
    }
    double localMinValue = data[iStart];
    double localMaxValue = localMinValue;
    for (int i = iStart; i < iEnd; i++) {
      int t = startTimeMuS + samplingPeriodInMicroSeconds*i;
      if (t >= t0MuS && t <= t1MuS) {
        var value = data[i];
        localMinValue = min(localMinValue, value); 
        localMaxValue = max(localMaxValue, value); 
      }
    }
    return Float64x2(localMinValue, localMaxValue);
  }
}

/// @brief Utility to decimate for plotting.  In this case, we are drawing
///        vertical lines between the min and max value in a chunk.
/// @param[in] factor  The decimation factor.  For example, if this is
///                    5 then samples the min/max of data[0:5], 
///                    data[5:10], ... will be computed.
/// @param[in] data    The time series data to decimate.
/// @result The data decimated for plotting.  This is an array
///         whose length is nChunks x 2 where the first element
///         is the min value in the chunk and second value is the
///         max value in the chunk.
Float64x2List decimateForPlotting(int factor, Float64List data) {
    // Doesn't make sense
  if (factor < 1) {
    throw 'Plot decimation factor $factor must be positive';
  }
  int nSamples = data.length;
  if (nSamples == 0) {
    return Float64x2List(0); 
  }
  // This is super wonky - why are you doing this?
  if (nSamples < factor) {
    double dMin = data.reduce(min);
    double dMax = data.reduce(max);
    return Float64x2List.fromList( [Float64x2(dMin, dMax)] );
  }
  // Okay, we now have at least one chunk.  Let's estimate the output space.
  int nChunks = (nSamples/factor).floor();
  // The one edge case is when we go over 1 sample.  Then min/max collapses
  // to a point.  Otherwise, if there are more than 1 extra elements we can
  // squeeze in a vertical line.
  int remainder = nSamples%factor;
  if (remainder != 0 && nSamples - factor*nChunks > 1) {
    nChunks = nChunks + 1;
  }

  var decimatedData = Float64x2List(nChunks);
  for (int block = 0; block < nChunks; block++) {
    int startSample = block*factor;
    int endSample = startSample + factor;
    if (block == nChunks - 1){endSample = nSamples;}
    double dMin = data[startSample];
    double dMax = dMin;
    for (int s = startSample + 1; s < endSample; s++) {
      double sample = data[s];
      dMin = min(sample, dMin);
      dMax = max(sample, dMax);
    }
    decimatedData[block] = Float64x2(dMin, dMax);
  }
  return decimatedData;
}
