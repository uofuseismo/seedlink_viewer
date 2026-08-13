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
} SEEDLinkConnectionOptions;

typedef struct Packet
{
    double *data;      // Typically we'll get int packets but we'll eventually want doubles
    char network[NETWORK_SIZE];   // Network code
    char station[STATION_SIZE];   // Station code
    char channel[CHANNEL_SIZE];   // Channel code
    char location[LOCATION_SIZE];  // Location code
    int64_t startTime; // Packet start time in seconds since epoch.
    double samplingRate; // Sampling rate in hz
    int nSamples;      // Number of samples in packet.
} Packet;

typedef struct Packets
{
    struct Packet *packets;
    int nPackets;
} Packets;

typedef struct SEEDLinkConnection
{
    void *connection;    // Opaque pointer to the SEEDLink connection.
    bool isReady;        // True indicates the connection is ready to use.
    bool hasConnection;  // True indicates the connection pointer exists.
} SEEDLinkConnection;

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
/// @param[out] streams    The available streams.  Each stream is named
///                        NET.STA.CHAN.LOC and an absent location code is
///                        written as --.  Release this with freeStreams.
/// @result 0 indicates success.
FFI_PLUGIN_EXPORT
    intptr_t getStreams(SEEDLinkConnection *connection, StreamsList *streams);

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
