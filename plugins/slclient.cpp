#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <string>
#include <thread>
#include <vector>
#include <libslink.h>
#include <boost/json.hpp>
// Compiles Boost.JSON into this translation unit so there is no library to
// link and bundle alongside libslink/libmseed.  This must appear in exactly
// one source file.
#include <boost/json/src.hpp>
#include "slclient.hpp"

namespace
{

/// Splits a string on a delimiter - e.g., the UU_ARUT station identifiers
/// and 01_H_H_Z stream identifiers that SEEDLink v4 reports.
std::vector<std::string> split(const std::string &value, const char delimiter)
{
    std::vector<std::string> result;
    size_t start{0};
    while (true)
    {
        auto next = value.find(delimiter, start);
        if (next == std::string::npos)
        {
            result.push_back(value.substr(start));
            break;
        }
        result.push_back(value.substr(start, next - start));
        start = next + 1;
    }
    return result;
}

/// Reads a string member from a JSON object and returns an empty string when
/// the member is absent or is not a string.
std::string getString(const boost::json::object &object, const char *key)
{
    auto value = object.if_contains(key);
    if (value == nullptr){return "";}
    auto string = value->if_string();
    if (string == nullptr){return "";}
    return std::string{string->c_str()};
}

/// Copies the stream names into the C structure that dart owns.
intptr_t setStreamsList(const std::vector<std::string> &streamNames,
                        StreamsList *streams)
{
    streams->streams = nullptr;
    streams->nStreams = 0;
    if (streamNames.empty()){return 0;}
    auto result
        = static_cast<char **> (calloc(streamNames.size(), sizeof(char *)));
    if (result == nullptr)
    {
        std::cerr << "Failed to allocate stream list" << std::endl;
        return -1;
    }
    for (size_t i = 0; i < streamNames.size(); ++i)
    {
        result[i] = strdup(streamNames[i].c_str());
        if (result[i] == nullptr)
        {
            std::cerr << "Failed to allocate stream name" << std::endl;
            for (size_t j = 0; j < i; ++j){free(result[j]);}
            free(result);
            return -1;
        }
    }
    streams->streams = result;
    streams->nStreams = static_cast<int> (streamNames.size());
    return 0;
}

}

FFI_PLUGIN_EXPORT intptr_t createConnection(
    const SEEDLinkConnectionOptions *options,
    SEEDLinkConnection *connection)
{
    if (connection == nullptr)
    {
        std::cerr << "Connection is null" << std::endl;
        return -1;
    }
    connection->connection = nullptr;
    connection->isReady = false;
    connection->hasConnection = false;

    if (options == nullptr)
    {
        std::cerr << "Options is null" << std::endl;
        return -1;
    }

    const std::string clientName{"wave_viewer_client"};
    // TODO should lift this from the package
    const std::string clientVersion{"0.0.1"};
    auto slConnection = sl_initslcd(clientName.c_str(),
                              clientVersion.c_str());
    connection->connection = reinterpret_cast<void *> (slConnection);
    connection->hasConnection = true;
 
    const auto address = std::string{options->host}
                       + ":" + std::to_string(options->port);
    if (sl_set_serveraddress(slConnection, address.c_str()) != 0)
    {
        std::cerr << "Failed to set seedlink server address to : "
                  << address << std::endl;
        return -1;
    }
    // TODO - have to figure out where cert goes
    // library appears to check the known players in /etc/ssl/ and /etc/pki/
    // ENV variables in play: LIBSLINK_TLS_CERT_FILE and LIBSLINK_TLS_CERT_PATH
    sl_set_tlsmode(slConnection, false);
    if (options->useTLS)
    {
        constexpr int tlsMode{1};
        sl_set_tlsmode(slConnection, 1);
    }
    // Return quickly if no data
    constexpr bool nonBlock{true};
    sl_set_blockingmode(slConnection, nonBlock);
    // Do not close connection after last packet
    constexpr bool closeConnection{false};
    sl_set_dialupmode(slConnection, closeConnection);
    connection->isReady = true;
    return 0;
}

FFI_PLUGIN_EXPORT 
    intptr_t getServerIdentifier(SEEDLinkConnection *connection,
                                 char result[1026])
{
    constexpr size_t MAX_SIZE{1026};
    std::memset(result, '\0', MAX_SIZE);
    if (connection->connection == nullptr || !connection->hasConnection)
    {
        std::cerr << "Connection is null" << std::endl;
        return -1;
    }
    if (!connection->isReady)
    {
        std::cerr << "Connection not ready" << std::endl;
        return -1;
    }
   
    std::string slSite(512, '\0');
    std::string slServerID(512, '\0');
    auto slConnection = reinterpret_cast<SLCD *> (connection->connection);
    auto returnCode = sl_ping(slConnection, slServerID.data(), slSite.data());
    if (returnCode != 0)
    {
        if (returnCode ==-1)
        {
            std::cerr << "Invalid ping response" << std::endl;
        }
        else
        {
            std::cerr << "Could not connect to server" << std::endl;
        }
        return -2;
    }
    // These come out null terminated
    std::string name = slSite + " " + slServerID;
    std::memcpy(result, name.data(), std::min(name.size(), MAX_SIZE));
    return 0;
}

FFI_PLUGIN_EXPORT void freeConnection(SEEDLinkConnection *connection)
{
    if (connection)
    {
        if (connection->hasConnection)
        {
            auto slConnection = reinterpret_cast<SLCD *> (connection->connection);
            sl_freeslcd(slConnection);
            connection->connection = nullptr;
            connection->hasConnection = false;
        }
    }
}

FFI_PLUGIN_EXPORT void freePacket(Packet *packet)
{
    if (packet != nullptr)
    {
        if (packet->data != nullptr && packet->nSamples > 0)
        {
            free(packet->data);
        }
        std::memset(packet->network,  '\0', NETWORK_SIZE);
        std::memset(packet->station,  '\0', STATION_SIZE);
        std::memset(packet->channel,  '\0', CHANNEL_SIZE);
        std::memset(packet->location, '\0', LOCATION_SIZE);
        packet->startTime = 0;
        packet->samplingRate = 0;
        packet->nSamples = 0;
    }
}

FFI_PLUGIN_EXPORT void freePackets(Packets *packets)
{
    if (packets != nullptr)
    {
        if (packets->nPackets > 0)
        {
            for (int i = 0; i < packets->nPackets; ++i)
            {
                freePacket(&packets->packets[i]);
            }
            free(packets->packets);
        }
        packets->nPackets = 0;
    }
}

FFI_PLUGIN_EXPORT void freeStreams(StreamsList *streams)
{
    if (streams != nullptr)
    {
        auto nStreams = streams->nStreams; 
        if (streams->streams != nullptr)
        {
            for (int i = 0; i < nStreams; ++i)
            {
                if (streams->streams[i] != nullptr)
                {
                    free(streams->streams[i]);
                    streams->streams[i] = nullptr;
                }
            }
            free(streams->streams);
            streams->streams = nullptr;
        }
        streams->nStreams = 0;
    }
}

FFI_PLUGIN_EXPORT
    intptr_t parseStreamsResponse(const char *response, StreamsList *streams)
{
    if (streams == nullptr)
    {
        std::cerr << "Streams is null" << std::endl;
        return -1;
    }
    streams->streams = nullptr;
    streams->nStreams = 0;
    if (response == nullptr)
    {
        std::cerr << "Response is null" << std::endl;
        return -1;
    }

    std::vector<std::string> streamNames;
    try
    {
        boost::system::error_code errorCode;
        auto jsonValue = boost::json::parse(response, errorCode);
        if (errorCode)
        {
            std::cerr << "Failed to parse INFO STREAMS response: "
                      << errorCode.message() << std::endl;
            return -1;
        }
        auto root = jsonValue.if_object();
        if (root == nullptr)
        {
            std::cerr << "INFO STREAMS response is not an object" << std::endl;
            return -1;
        }
        // A server with nothing to offer simply omits the station list
        auto stations = root->if_contains("station");
        if (stations == nullptr){return 0;}
        auto stationArray = stations->if_array();
        if (stationArray == nullptr)
        {
            std::cerr << "INFO STREAMS station list is not an array"
                      << std::endl;
            return -1;
        }
        for (const auto &stationValue : *stationArray)
        {
            auto station = stationValue.if_object();
            if (station == nullptr){continue;}
            // Station identifiers look like UU_ARUT
            auto stationFields = split(getString(*station, "id"), '_');
            if (stationFields.size() != 2){continue;}
            const auto &network = stationFields.at(0);
            const auto &stationCode = stationFields.at(1);
            auto seedLinkStreams = station->if_contains("stream");
            if (seedLinkStreams == nullptr){continue;}
            auto streamArray = seedLinkStreams->if_array();
            if (streamArray == nullptr){continue;}
            for (const auto &streamValue : *streamArray)
            {
                auto stream = streamValue.if_object();
                if (stream == nullptr){continue;}
                // Stream identifiers look like 01_H_H_Z - i.e., the location
                // code followed by the band, source, and position codes that
                // make up the channel.
                auto streamFields = split(getString(*stream, "id"), '_');
                if (streamFields.size() < 2){continue;}
                const auto &location = streamFields.at(0);
                std::string channel;
                for (size_t i = 1; i < streamFields.size(); ++i)
                {
                    channel = channel + streamFields.at(i);
                }
                streamNames.push_back(network + "." + stationCode + "."
                                    + channel + "."
                                    + (location.empty() ? "--" : location));
            }
        }
    }
    catch (const std::exception &e)
    {
        std::cerr << "Failed to parse INFO STREAMS response: "
                  << e.what() << std::endl;
        return -1;
    }
    std::sort(streamNames.begin(), streamNames.end());
    streamNames.erase(std::unique(streamNames.begin(), streamNames.end()),
                      streamNames.end());
    return setStreamsList(streamNames, streams);
}

FFI_PLUGIN_EXPORT
    intptr_t getStreams(SEEDLinkConnection *connection, StreamsList *streams)
{
    if (connection == nullptr ||
        connection->connection == nullptr || !connection->hasConnection)
    {
        std::cerr << "Connection is null" << std::endl;
        return -1;
    }
    if (!connection->isReady)
    {
        std::cerr << "Connection not ready" << std::endl;
        return -1;
    }
    if (streams == nullptr)
    {
        std::cerr << "Streams is null" << std::endl;
        return -1;
    }
    streams->streams = nullptr;
    streams->nStreams = 0;
    auto slConnection = reinterpret_cast<SLCD *> (connection->connection);
    auto returnValue = sl_request_info(slConnection, "STREAMS");
    if (returnValue != 0)
    {
        std::cerr << "Failed to set STREAMS info request" << std::endl;
        return -1;
    }
    // sl_request_info only queues the request - the next sl_collect actually
    // sends it.  The connection is non-blocking so sl_collect will report
    // SLNOPACKET until the server gets around to answering; poll until the
    // response shows up or we run out of patience.
    constexpr auto timeOut = std::chrono::seconds{10};
    const auto giveUpTime = std::chrono::steady_clock::now() + timeOut;
    std::vector<char> buffer(SL_RECV_BUFFER_SIZE);
    std::string payload;
    bool haveResponse{false};
    while (std::chrono::steady_clock::now() < giveUpTime)
    {
        const SLpacketinfo *packetInfo{nullptr};
        returnValue = sl_collect(slConnection, &packetInfo, buffer.data(),
                                 static_cast<uint32_t> (buffer.size()));
        if (returnValue == SLPACKET)
        {
            if (packetInfo == nullptr){continue;}
            // v4 servers answer an INFO request with a single JSON payload.
            // Anything else is data that was already in flight so skip it.
            if (packetInfo->payloadformat == SLPAYLOAD_JSON &&
                packetInfo->payloadlength > 0)
            {
                payload.assign(buffer.data(), packetInfo->payloadlength);
                haveResponse = true;
                break;
            }
        }
        else if (returnValue == SLTOOLARGE)
        {
            // The response grows with the number of streams on the server and
            // readily outgrows libslink's internal receive buffer.  Resize and
            // let sl_collect hand us the packet again.
            if (packetInfo == nullptr ||
                packetInfo->payloadlength <= buffer.size())
            {
                std::cerr << "Cannot resize buffer for payload" << std::endl;
                return -1;
            }
            buffer.resize(packetInfo->payloadlength);
        }
        else if (returnValue == SLNOPACKET)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds{10});
        }
        else if (returnValue == SLTERMINATE)
        {
            std::cerr << "Server terminated the connection" << std::endl;
            return -2;
        }
        else if (returnValue == SLAUTHFAIL)
        {
            std::cerr << "Authentication failed" << std::endl;
            return -1;
        }
        else
        {
            std::cerr << "Unhandled return code from sl_collect: "
                      << returnValue << std::endl;
            return -1;
        }
    }
    if (!haveResponse)
    {
        std::cerr << "Timed out waiting for the INFO STREAMS response"
                  << std::endl;
        return -3;
    }
    return parseStreamsResponse(payload.c_str(), streams);
}

FFI_PLUGIN_EXPORT 
    intptr_t getPackets(SEEDLinkConnection *connection,
                        const int maxPackets,
                        Packets *packets)
{
    if (connection->connection == nullptr || !connection->hasConnection)
    {
        std::cerr << "Connection is null" << std::endl;
        return -1;
    }
    if (!connection->isReady)
    {
        std::cerr << "Connection not ready" << std::endl;
        return -1;
    }
    if (maxPackets < 1)
    {
        std::cerr << "Max number of packets to read must be positive"
                  << std::endl;
        return -1;
    }
    // Get a handle on the connection 
    auto slConnection = reinterpret_cast<SLCD *> (connection->connection);
    // Read as much as we can (or up until the given chunk size)
    for (int k = 0; k < maxPackets; ++k)
    {
        const SLpacketinfo *seedLinkPacketInfo{nullptr};
        std::array<char, SL_RECV_BUFFER_SIZE> seedLinkBuffer;
        auto returnValue = sl_collect(slConnection, 
                                      &seedLinkPacketInfo,
                                      seedLinkBuffer.data(),
                                      SL_RECV_BUFFER_SIZE);
        // Data! 
        if (seedLinkPacketInfo->payloadformat == SLPAYLOAD_MSEED2 ||
            seedLinkPacketInfo->payloadformat == SLPAYLOAD_MSEED3)
        {
            std::cout << "Got data" << std::endl;
        }
        else if (returnValue == SLTOOLARGE)
        {
            std::cerr << "Internal error: Payload length "
                      << seedLinkPacketInfo->payloadlength
                      << " exceeds buffer size " << SL_RECV_BUFFER_SIZE
                      << std::endl;
        }
        else if (returnValue == SLTERMINATE)
        {
            std::cerr << "Server issued terminate command - destroy this connection and reconnect" << std::endl;
            return -2;
        }
        else
        {
            std::cerr << "Unhandled SEEDLink return value: "
                      << returnValue << std::endl;
        }
    }
    return 0;
}
