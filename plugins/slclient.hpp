#ifndef SLCLIENT_HPP
#define SLCLIENT_HPP
#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#if _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

#define NETWORK_SIZE 8
#define STATION_SIZE 8
#define CHANNEL_SIZE 8
#define LOCATION_SIZE 8
#define HOST_SIZE 256

// Sized to each platform's longest path.  Spelled out rather than using
// PATH_MAX because that needs <limits.h> and does not exist on Windows.
// This makes the struct a different size per platform, so the dart bindings
// have to be regenerated per platform - CI already does that before building.
#if __APPLE__
#define CERTIFICATE_PATH_SIZE 1024   // Darwin PATH_MAX
#elif _WIN32
#define CERTIFICATE_PATH_SIZE 260    // MAX_PATH
#else
#define CERTIFICATE_PATH_SIZE 4096   // Linux PATH_MAX
#endif
// Matches libslink's SL_UNSETSEQUENCE.  Note dart reads this as -1 because
// its integers are signed.
#define UNSET_SEQUENCE_NUMBER UINT64_MAX

typedef struct StreamsList
{
    char **streams;
    int nStreams;
} StreamsList;

typedef struct SEEDLinkConnectionOptions
{
    char *host;        // null terminated name of host - e.g., localhost
    uint16_t port;     // Port number - e.g., 18000
    bool useTLS;       // Use TLS - true indicates using TLS (false for now)
    // Seconds between keepalive heartbeats, or 0 for none.
    //
    // libslink disconnects a connection that has been idle for netto seconds
    // (600 by default) and then waits netdly (30) before reconnecting, so a
    // long lived acquisition on a quiet channel would drop every ten minutes
    // and leave a half minute hole.  A heartbeat keeps it up.  Short lived
    // queries do not need one - they are done in a second.
    int keepAliveSeconds;
    // Path to the CA certificate to trust, or empty for the system defaults.
    // Only consulted when useTLS is true.
    //
    // NOT YET APPLIED: libslink's only TLS control is sl_set_tlsmode, and it
    // locates certificates from the LIBSLINK_TLS_CERT_FILE and
    // LIBSLINK_TLS_CERT_PATH environment variables or a built-in list of
    // system locations. There is no per-connection setter, so honouring this
    // means setting those variables for the whole process before connecting.
    char certificatePath[CERTIFICATE_PATH_SIZE];
} SEEDLinkConnectionOptions;

typedef struct Packet
{
    double *data;      // Typically we'll get int packets but we'll eventually want doubles
    char network[NETWORK_SIZE];   // Network code
    char station[STATION_SIZE];   // Station code
    char channel[CHANNEL_SIZE];   // Channel code
    char location[LOCATION_SIZE];  // Location code
    int64_t startTime; // Packet start time in nanoseconds since epoch.
    double samplingRate; // Sampling rate in hz
    int nSamples;      // Number of samples in packet.
    uint64_t sequenceNumber; // The SEEDLink sequence number of this packet, or
                             // UNSET_SEQUENCE_NUMBER.  Retaining the last one
                             // seen for a station lets a rebuilt connection
                             // resume from that point rather than leaving a
                             // hole in the record.
} Packet;

typedef struct Packets
{
    struct Packet *packets;
    int nPackets;
} Packets;

typedef struct SEEDLinkConnection
{
    void *connection;      // Opaque pointer to the SEEDLink connection.
    char host[HOST_SIZE];  // The server host.  Retained because modifySelections
    uint16_t port;         // has to build a replacement connection and libslink
    bool useTLS;           // offers no way to read these back.
    int keepAliveSeconds;  // Kept for the same reason.
    bool isReady;          // True indicates the connection is ready to use.
    bool hasConnection;    // True indicates the connection pointer exists.
} SEEDLinkConnection;

/// The size of SEEDLinkConnectionOptions.certificatePath on this platform.
/// It varies by platform and the generated dart bindings do not carry macros,
/// so callers ask for it rather than assuming a value.
FFI_PLUGIN_EXPORT int getCertificatePathSize(void);

/// Creates the connection from the inpu toptions.
FFI_PLUGIN_EXPORT intptr_t createConnection(const SEEDLinkConnectionOptions *options,
                                            SEEDLinkConnection *result);

/// Pings the SEEDLink server and gets its name.
/// @param[in] connection  Holds the SEEDLink connection.
/// @param[out] result     The SEEDLink server name.
/// @result 0 indicates success.
FFI_PLUGIN_EXPORT intptr_t getServerIdentifier(SEEDLinkConnection *connection,
                                               char result[1026]);

/// Generates a list of currently available streams.
/// @param[in] connection  Holds the SEEDLink connection.
/// @param[in] timeOutMilliSeconds  Give up if the server has not answered in
///                        this long.  A busy server with many thousands of
///                        streams can take a while to compose the reply.
/// @param[out] streams    The available streams.  Each stream is named
///                        NET.STA.CHAN.LOC and an absent location code is
///                        written as --.  Release this with freeStreams.
/// @result 0 indicates success.
FFI_PLUGIN_EXPORT
    intptr_t getStreams(SEEDLinkConnection *connection,
                        int timeOutMilliSeconds,
                        StreamsList *streams);

/// Converts a SEEDLink v4 INFO STREAMS response into a list of stream names.
/// This is the parsing half of getStreams split out so it can be exercised
/// against a canned response without touching the network.
/// @param[in] response  The null terminated JSON payload returned by the
///                      server for an INFO STREAMS request.
/// @param[out] streams  The streams named in the response.  See getStreams
///                      for the naming.  Release this with freeStreams.
/// @result 0 indicates success.
FFI_PLUGIN_EXPORT
    intptr_t parseStreamsResponse(const char *response, StreamsList *streams);
/// Frees the streams structure.
/// @param[in,out] streams  On input this is the streams structure to free.
///                         On exit, the memory on streams has been released.
FFI_PLUGIN_EXPORT
     void freeStreams(StreamsList *streams);


/// Sets the streams the server should send on this connection.
///
/// SEEDLink only accepts stream selections while a connection is being
/// negotiated, and libslink only negotiates immediately after connecting -
/// a selection sent mid-acquisition is ignored by the server.  There is also
/// no way to drop a station from an existing connection.  This therefore
/// builds a replacement connection and retires the old one.  The sequence
/// number each station had reached is carried across so the reconnect
/// resumes rather than leaving a hole in the record, and stations that were
/// not previously selected start with whatever the server sends next.
///
/// The connection reconnects and renegotiates on the next getPackets call, so
/// expect a short gap in the data while that happens.  Selections are worth
/// batching - do not call this once per channel the user clicks.
///
/// @param[in,out] connection  On input, the connection to modify.  On exit,
///                            the connection requests the given streams.
/// @param[in] streams         The desired streams named NET.STA.CHAN.LOC, as
///                            produced by getStreams.  Only data records are
///                            requested.  Names that cannot be parsed are
///                            skipped.
/// @result 0 indicates success.  On failure the original connection is left
///         untouched.
FFI_PLUGIN_EXPORT
    intptr_t modifySelections(SEEDLinkConnection *connection,
                              const StreamsList *streams);

/// Reads packets from a SEEDLink server.
/// @param[in] connection  A container with the connection information.
/// @param[in] maxPackets  We read chunks of packets at a time so we don't
///                        get stuck indefinitely in this function.  This
///                        is the maximum number of packets to read.
/// @param[out] packets    The packets read.
FFI_PLUGIN_EXPORT intptr_t getPackets(SEEDLinkConnection *connection, int maxPackets, Packets *packets);

/// Frees the packest read from getPackets.
/// @param[in,out] packets  On input, the packets container to free.
///                         On exit, the memory on packets has been freed.
FFI_PLUGIN_EXPORT void freePackets(Packets *packets);
/// Utility to free the memory on an individual packet.  Likely won't be
/// called from dart.
FFI_PLUGIN_EXPORT void freePacket(Packet *packet);

FFI_PLUGIN_EXPORT void freeConnection(SEEDLinkConnection *connection);

/*
// A very short-lived native function.
//
// For very short-lived functions, it is fine to call them on the main isolate.
// They will block the Dart execution while running the native function, so
// only do this for native functions which are guaranteed to be short-lived.
FFI_PLUGIN_EXPORT intptr_t sum(intptr_t a, intptr_t b);

// A longer lived native function, which occupies the thread calling it.
//
// Do not call these kind of native functions in the main isolate. They will
// block Dart execution. This will cause dropped frames in Flutter applications.
// Instead, call these native functions on a separate isolate.
FFI_PLUGIN_EXPORT intptr_t sum_long_running(intptr_t a, intptr_t b);
*/

#ifdef __cplusplus
}
#endif
#endif
