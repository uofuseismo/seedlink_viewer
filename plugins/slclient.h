#ifndef SLCLIENT_H
#define SLCLIENT_H
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

typedef struct ChannelList
{
    char **channels;
    int nChannels;
} ChannelList;

typedef struct SEEDLinkConnectionOptions
{
    char *host;    // null terminated name of host - e.g., localhost
    uint16_t port; // port number - e.g., 18000
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

FFI_PLUGIN_EXPORT intptr_t createConnection(const SEEDLinkConnectionOptions *options,
                                            SEEDLinkConnection *result);

/// Pings the SEEDLink server and gets its name.
/// @param[in] connection  Holds the SEEDLink connection.
/// @param[out] result     The SEEDLink server name.
/// @result 0 indicates success.
FFI_PLUGIN_EXPORT intptr_t getServerIdentifier(SEEDLinkConnection *connection,
                                               char result[1026]);

FFI_PLUGIN_EXPORT intptr_t getPackets(SEEDLinkConnection *connection, Packets *packets);

FFI_PLUGIN_EXPORT void freePackets(Packets *packets);

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
