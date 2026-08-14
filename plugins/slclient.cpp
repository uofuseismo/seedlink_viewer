#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <limits>
#include <map>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>
#include <libslink.h>
#include <libmseed.h>
#include <boost/algorithm/string/trim.hpp>
#include <boost/json.hpp>
// Compiles Boost.JSON into this translation unit so there is no library to
// link and bundle alongside libslink/libmseed.  This must appear in exactly
// one source file.
#include <boost/json/src.hpp>
#include "slclient.hpp"

namespace
{

const std::string CLIENT_NAME{"wave_viewer_client"};
// TODO should lift this from the package
const std::string CLIENT_VERSION{"0.0.1"};

#if _WIN32
#define SET_ENVIRONMENT(name, value) _putenv_s(name, value)
#define UNSET_ENVIRONMENT(name) _putenv_s(name, "")
#else
#define SET_ENVIRONMENT(name, value) setenv(name, value, 1)
#define UNSET_ENVIRONMENT(name) unsetenv(name)
#endif

/// Points libslink at the certificate authority certificates to trust.
///
/// libslink has no per-connection setter for this - load_ca_certs only reads
/// the environment - so this necessarily applies to the whole process. That is
/// tolerable while the application holds one connection at a time.
///
/// N.B. libslink's documentation and its own log messages call these
/// LIBSLINK_TLS_CERT_FILE and LIBSLINK_TLS_CERT_PATH, but load_ca_certs
/// actually reads LIBSLINK_CA_CERT_FILE and LIBSLINK_CA_CERT_PATH. Both
/// spellings are written so this keeps working whichever way that gets
/// reconciled upstream.
intptr_t applyCertificatePath(const std::string &certificatePath)
{
    const std::array<const char *, 2> fileVariables
    {
        "LIBSLINK_CA_CERT_FILE", "LIBSLINK_TLS_CERT_FILE"
    };
    const std::array<const char *, 2> pathVariables
    {
        "LIBSLINK_CA_CERT_PATH", "LIBSLINK_TLS_CERT_PATH"
    };
    // Nothing chosen, so clear whatever an earlier connection left behind and
    // let libslink fall back to the system locations it already knows about.
    if (certificatePath.empty())
    {
        for (auto name : fileVariables){UNSET_ENVIRONMENT(name);}
        for (auto name : pathVariables){UNSET_ENVIRONMENT(name);}
        return 0;
    }

    std::error_code errorCode;
    if (!std::filesystem::exists(certificatePath, errorCode) || errorCode)
    {
        std::cerr << "Certificate path " << certificatePath
                  << " does not exist" << std::endl;
        return -1;
    }
    // A directory holds a pile of certificates and a file is a single bundle.
    // Accept either so picking a bundle by mistake still does what was meant.
    const bool isDirectory
        = std::filesystem::is_directory(certificatePath, errorCode) &&
          !errorCode;
    const auto &wanted = isDirectory ? pathVariables : fileVariables;
    const auto &unwanted = isDirectory ? fileVariables : pathVariables;
    for (auto name : unwanted){UNSET_ENVIRONMENT(name);}
    for (auto name : wanted)
    {
        if (SET_ENVIRONMENT(name, certificatePath.c_str()) != 0)
        {
            std::cerr << "Failed to set " << name << std::endl;
            return -1;
        }
    }
    return 0;
}

/// Applies the connection settings this client always wants.
void setConnectionOptions(SLCD *slConnection,
                          const bool useTLS,
                          const int keepAliveSeconds)
{
    // TODO - have to figure out where cert goes
    // library appears to check the known players in /etc/ssl/ and /etc/pki/
    // ENV variables in play: LIBSLINK_TLS_CERT_FILE and LIBSLINK_TLS_CERT_PATH
    sl_set_tlsmode(slConnection, useTLS ? 1 : 0);
    // Return quickly if no data
    constexpr bool nonBlock{true};
    sl_set_blockingmode(slConnection, nonBlock);
    // Do not close connection after last packet
    constexpr bool closeConnection{false};
    sl_set_dialupmode(slConnection, closeConnection);
    // Off by default in libslink.  Without it an acquisition that goes quiet
    // is dropped after the idle timeout and leaves a hole in the record.
    if (keepAliveSeconds > 0)
    {
        sl_set_keepalive(slConnection, keepAliveSeconds);
    }
    // libslink waits 30 seconds before retrying a failed connection, which is
    // a long time to stare at an empty plot.  It matters more than it looks:
    // sockconnect_int treats only EINPROGRESS and EWOULDBLOCK as retryable, so
    // a connect interrupted by a signal - which happens readily inside a dart
    // isolate - fails outright and then sits out the whole delay.
    constexpr int reconnectDelaySeconds{5};
    sl_set_reconnectdelay(slConnection, reconnectDelaySeconds);
}

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

/// Turns a NET.STA.CHAN.LOC stream name into the station identifier and the
/// selector libslink wants for it.  False indicates the name is unusable.
bool toStationAndSelector(const std::string &name,
                          std::string &stationID,
                          std::string &selector)
{
    auto fields = split(name, '.');
    if (fields.size() < 3 || fields.size() > 4){return false;}
    const auto &network = fields.at(0);
    const auto &station = fields.at(1);
    const auto &channel = fields.at(2);
    // getStreams writes an absent location code as --
    auto location = (fields.size() == 4) ? fields.at(3) : std::string{};
    if (location == "--"){location.clear();}
    if (network.empty() || station.empty() || channel.size() < 3){return false;}
    stationID = network + "_" + station;
    // We only ever want data records
    const std::string type{".D"};
    if (channel.size() == 3)
    {
        // libslink rewrites v3 selectors (LLCCC.T) into the v4 spelling
        // (LL_B_S_SS.T) itself, so the v3 form works against either server.
        // That conversion strips leading - back to an empty location code.
        selector = (location.empty() ? "--" : location) + channel + type;
    }
    else
    {
        // Channels that are not the 3 character SEED code have no v3 spelling
        // so write the v4 band_source_subsource form directly.
        selector = location + "_" + channel.substr(0, 1)
                 + "_" + channel.substr(1, 1)
                 + "_" + channel.substr(2) + type;
    }
    return true;
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

Packet miniSEEDToPacket(const MS3Record &miniSEEDRecord)
{
    // Value initialised: an early throw would otherwise leave the caller
    // looking at uninitialised codes, and nothing else sets sequenceNumber.
    Packet packet{};
    packet.sequenceNumber = UNSET_SEQUENCE_NUMBER;
    // Some simple stuff
    if (miniSEEDRecord.samprate <= 0)
    {
        throw std::invalid_argument("Sampling rate must be positive");
    }    
    packet.samplingRate = miniSEEDRecord.samprate;
    // Number of samples            
    auto nSamples = static_cast<int> (miniSEEDRecord.numsamples);
    if (nSamples <= 0)
    {   
        throw std::invalid_argument("Empty data packet");
    }   
    packet.nSamples = nSamples;
    // Start time
    std::chrono::nanoseconds startTime
    {   
        static_cast<int64_t> (miniSEEDRecord.starttime)
    };  
    packet.startTime = startTime.count();
    // SNCL
    std::array<char, NETWORK_SIZE> networkWork;
    std::array<char, STATION_SIZE> stationWork;
    std::array<char, CHANNEL_SIZE> channelWork;
    std::array<char, LOCATION_SIZE> locationWork;
    std::fill(networkWork.begin(),  networkWork.end(),  '\0');
    std::fill(stationWork.begin(),  stationWork.end(),  '\0');
    std::fill(channelWork.begin(),  channelWork.end(),  '\0');
    std::fill(locationWork.begin(), locationWork.end(), '\0');
    auto returnCode = ms_sid2nslc_n(miniSEEDRecord.sid,
                                    networkWork.data(),  networkWork.size(),
                                    stationWork.data(),  stationWork.size(),
                                    locationWork.data(), locationWork.size(),
                                    channelWork.data(),  channelWork.size());
    if (returnCode == MS_NOERROR)
    {
        // This is all small string optimization
        std::string network(networkWork.data());
        std::string station(stationWork.data());
        std::string channel(channelWork.data());
        std::string locationCode(locationWork.data());

        boost::algorithm::trim(network);
        if (network.empty()){throw std::runtime_error("Network is empty");}
        std::transform(network.begin(), network.end(), network.begin(),
                       ::toupper);

        boost::algorithm::trim(station);
        if (station.empty()){throw std::runtime_error("Station is empty");}
        std::transform(station.begin(), station.end(), station.begin(),
                       ::toupper);

        boost::algorithm::trim(channel);
        if (channel.empty()){throw std::runtime_error("Channel is empty");}
        std::transform(channel.begin(), channel.end(), channel.begin(),
                       ::toupper);
        if (channel.empty()){throw std::runtime_error("Channel is empty");}

        if (!locationCode.empty())
        {
            boost::algorithm::trim(locationCode);
            std::transform(locationCode.begin(), locationCode.end(),
                           locationCode.begin(), ::toupper);
        }
        if (locationCode.empty()){locationCode = "--";}

        // Copy it
        std::strcpy(packet.network,  network.c_str());
        std::strcpy(packet.station,  station.c_str());
        std::strcpy(packet.channel,  channel.c_str());
        std::strcpy(packet.location, locationCode.c_str());
    }
    else
    {
        throw std::runtime_error("Couldn't unpack station identifier");
    }
    // Heavy data - note we're always going to a double buffer
    packet.data = nullptr;
    if (packet.nSamples > 0)
    {
        // sizeof(double), not sizeof(double *) - the two happen to agree on
        // 64 bit but the pointer is 4 bytes on a 32 bit target, which would
        // undersize the buffer by half.
        packet.data
            = static_cast<double *> (calloc(packet.nSamples, sizeof(double)));
        if (packet.data == nullptr)
        {
            throw std::runtime_error("Failed to allocate packet samples");
        }
        if (miniSEEDRecord.sampletype == 'i')
        {
            const auto data
                = reinterpret_cast<const int *> (miniSEEDRecord.datasamples);
            std::copy(data, data + packet.nSamples, packet.data);
        }
        else if (miniSEEDRecord.sampletype == 'f')
        {
            const auto data
                = reinterpret_cast<const float *> (miniSEEDRecord.datasamples);
            std::copy(data, data + packet.nSamples, packet.data);
        }
        else if (miniSEEDRecord.sampletype == 'd')
        {
            const auto data
                = reinterpret_cast<const double *> (miniSEEDRecord.datasamples);
            std::copy(data, data + packet.nSamples, packet.data);
        }
        else
        {
            freePacket(&packet);
            throw std::invalid_argument("Unhandled data type");
        }
    }
    return packet;
}

std::vector<Packet>
    miniSEEDBufferToPackets(char *msRecord,
                            const int bufferSize)
{
    std::vector<Packet> dataPackets;
    auto bufferLength = static_cast<uint64_t> (bufferSize);
    uint64_t offset{0};
    int failedPacketConversions{0};
    // Iterate through the consumed buffer
    while (bufferLength - offset > MINRECLEN)
    {
        // Convert every packet in the buffer
        constexpr int8_t verbose{0};
        constexpr uint32_t flags{MSF_UNPACKDATA};
        MS3Record *miniSEEDRecord{nullptr};
        auto returnCode
            = msr3_parse(msRecord + offset,
                         static_cast<uint64_t> (bufferSize) - offset,
                         &miniSEEDRecord, flags,
                         verbose);
        if (returnCode == MS_NOERROR && miniSEEDRecord)
        {
            try
            {
                auto dataPacket = ::miniSEEDToPacket(*miniSEEDRecord);
                dataPackets.push_back(std::move(dataPacket));
            }
            catch (const std::exception &e)
            {
                failedPacketConversions = failedPacketConversions + 1;
                std::cerr << "Failed to convert packet because " 
                          << e.what() << std::endl;
            }
            offset = offset + miniSEEDRecord->reclen;
            msr3_free(&miniSEEDRecord);
        }
        else
        {
            if (returnCode != MS_NOERROR)
            {
                if (miniSEEDRecord){msr3_free(&miniSEEDRecord);}
                throw std::runtime_error("libmseed error detected");
            }
            msr3_free(&miniSEEDRecord);
            throw std::runtime_error(
                 "Insufficient data.  Number of additional bytes estimated is "
                + std::to_string(returnCode));
        }
    }
    if (failedPacketConversions > 0)
    {
        std::cerr << "Failed to convert " 
                  << failedPacketConversions
                  << " miniSEED packets" << std::endl;
    }
    return dataPackets; 
}

}

FFI_PLUGIN_EXPORT int getCertificatePathSize(void)
{
    return CERTIFICATE_PATH_SIZE;
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
    std::memset(connection->host, '\0', HOST_SIZE);
    connection->port = 0;
    connection->useTLS = false;
    connection->keepAliveSeconds = 0;
    connection->isReady = false;
    connection->hasConnection = false;

    if (options == nullptr)
    {
        std::cerr << "Options is null" << std::endl;
        return -1;
    }
    if (options->host == nullptr)
    {
        std::cerr << "Host is null" << std::endl;
        return -1;
    }
    const std::string host{options->host};
    if (host.size() >= HOST_SIZE)
    {
        std::cerr << "Host " << host << " is too long" << std::endl;
        return -1;
    }
    // The certificate path is fixed width, so refuse an oversized one rather
    // than quietly trusting a truncated path.
    if (options->useTLS)
    {
        if (options->certificatePath[CERTIFICATE_PATH_SIZE - 1] != '\0')
        {
            std::cerr << "Certificate path is not null terminated" << std::endl;
            return -1;
        }
        // An empty path means the system certificates, which libslink finds by
        // itself.  Deliberately not the working directory - the application is
        // launched from wherever, and pointing a trust store at that would be
        // both surprising and unsafe.
        const std::string certificatePath{options->certificatePath};
        if (applyCertificatePath(certificatePath) != 0)
        {
            return -1;
        }
    }
    // Remember how we got here so modifySelections can rebuild the connection
    std::memcpy(connection->host, host.data(), host.size());
    connection->port = options->port;
    connection->useTLS = options->useTLS;
    connection->keepAliveSeconds = options->keepAliveSeconds;

    auto slConnection = sl_initslcd(CLIENT_NAME.c_str(),
                                    CLIENT_VERSION.c_str());
    connection->connection = reinterpret_cast<void *> (slConnection);
    connection->hasConnection = true;

    const auto address = host + ":" + std::to_string(options->port);
    if (sl_set_serveraddress(slConnection, address.c_str()) != 0)
    {
        std::cerr << "Failed to set seedlink server address to : "
                  << address << std::endl;
        return -1;
    }
    setConnectionOptions(slConnection, options->useTLS,
                         options->keepAliveSeconds);
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
            // sl_freeslcd releases the memory but leaves the socket open
            sl_disconnect(slConnection);
            sl_freeslcd(slConnection);
            connection->connection = nullptr;
            connection->hasConnection = false;
            connection->isReady = false;
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
        packet->sequenceNumber = UNSET_SEQUENCE_NUMBER;
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
            // Null it as well, the way freeStreams does.  Leaving a dangling
            // pointer behind invites a second free or a read of freed memory.
            packets->packets = nullptr;
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
    intptr_t getStreams(SEEDLinkConnection *connection,
                        const int timeOutMilliSeconds,
                        StreamsList *streams)
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
    const auto giveUpTime
        = std::chrono::steady_clock::now()
        + std::chrono::milliseconds{std::max(timeOutMilliSeconds, 0)};
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
    intptr_t modifySelections(SEEDLinkConnection *connection,
                              const StreamsList *streams)
{
    if (connection == nullptr ||
        connection->connection == nullptr || !connection->hasConnection)
    {
        std::cerr << "Connection is null" << std::endl;
        return -1;
    }
    if (streams == nullptr)
    {
        std::cerr << "Streams is null" << std::endl;
        return -1;
    }
    if (streams->nStreams > 0 && streams->streams == nullptr)
    {
        std::cerr << "Streams list is null" << std::endl;
        return -1;
    }
    // SEEDLink negotiates one STATION command with a run of SELECT commands
    // beneath it so the requested channels have to be grouped by station.
    std::map<std::string, std::set<std::string>> selections;
    for (int i = 0; i < streams->nStreams; ++i)
    {
        if (streams->streams[i] == nullptr){continue;}
        std::string stationID;
        std::string selector;
        if (!toStationAndSelector(streams->streams[i], stationID, selector))
        {
            std::cerr << "Skipping unparsable stream name: "
                      << streams->streams[i] << std::endl;
            continue;
        }
        selections[stationID].insert(selector);
    }

    auto oldConnection = reinterpret_cast<SLCD *> (connection->connection);
    // Note where each station had got to so the reconnect picks up where it
    // left off instead of leaving a hole in the record.  libslink has no
    // getter for this but the stream list is a documented member.
    std::map<std::string, uint64_t> sequenceNumbers;
    for (auto stream = oldConnection->streams; stream != nullptr;
         stream = stream->next)
    {
        sequenceNumbers[stream->stationid] = stream->seqnum;
    }

    // Build the replacement before retiring the old connection so a failure
    // here leaves the caller with a connection that still works.
    auto newConnection = sl_initslcd(CLIENT_NAME.c_str(),
                                     CLIENT_VERSION.c_str());
    if (newConnection == nullptr)
    {
        std::cerr << "Failed to create the replacement connection" << std::endl;
        return -1;
    }
    const auto address = std::string{connection->host}
                       + ":" + std::to_string(connection->port);
    if (sl_set_serveraddress(newConnection, address.c_str()) != 0)
    {
        std::cerr << "Failed to set seedlink server address to : "
                  << address << std::endl;
        sl_freeslcd(newConnection);
        return -1;
    }
    // The rebuilt connection has to keep beating too
    setConnectionOptions(newConnection, connection->useTLS,
                         connection->keepAliveSeconds);

    for (const auto &selection : selections)
    {
        const auto &stationID = selection.first;
        std::string selectors;
        for (const auto &selector : selection.second)
        {
            if (!selectors.empty()){selectors = selectors + " ";}
            selectors = selectors + selector;
        }
        // Stations we were already reading resume from their last sequence
        // number.  Newly selected ones take whatever the server sends next.
        uint64_t sequenceNumber{SL_UNSETSEQUENCE};
        auto found = sequenceNumbers.find(stationID);
        if (found != sequenceNumbers.end()){sequenceNumber = found->second;}
        if (sl_add_stream(newConnection, stationID.c_str(), selectors.c_str(),
                          sequenceNumber, nullptr) != 0)
        {
            std::cerr << "Failed to select " << selectors
                      << " on " << stationID << std::endl;
            sl_freeslcd(newConnection);
            return -1;
        }
    }

    // The replacement is good so retire the old connection.  The next
    // getPackets will connect and negotiate the new selection.
    sl_disconnect(oldConnection);
    sl_freeslcd(oldConnection);
    connection->connection = reinterpret_cast<void *> (newConnection);
    connection->hasConnection = true;
    connection->isReady = true;
    return 0;
}

FFI_PLUGIN_EXPORT
    intptr_t getPackets(SEEDLinkConnection *connection,
                        const int maxPackets,
                        Packets *packets)
{
    if (packets == nullptr)
    {
        std::cerr << "Packets is null" << std::endl;
        return -1;
    }
    packets->packets = nullptr;
    packets->nPackets = 0;
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
    if (maxPackets < 1)
    {
        std::cerr << "Max number of packets to read must be positive"
                  << std::endl;
        return -1;
    }
    // Get a handle on the connection
    auto slConnection = reinterpret_cast<SLCD *> (connection->connection);
    std::vector<Packet> collected;
    std::array<char, SL_RECV_BUFFER_SIZE> seedLinkBuffer;
    // Read as much as we can (or up until the given chunk size)
    for (int k = 0; k < maxPackets; ++k)
    {
        const SLpacketinfo *seedLinkPacketInfo{nullptr};
        auto returnValue = sl_collect(slConnection,
                                      &seedLinkPacketInfo,
                                      seedLinkBuffer.data(),
                                      SL_RECV_BUFFER_SIZE);
        // The return value has to be checked before the packet info is
        // touched.  sl_collect leaves it null when it has nothing to describe,
        // and on a non-blocking connection that is most calls.
        if (returnValue == SLNOPACKET)
        {
            // Nothing waiting.  Come back later rather than spinning here.
            break;
        }
        if (returnValue == SLTERMINATE)
        {
            std::cerr << "Server issued terminate command - destroy this connection and reconnect" << std::endl;
            for (auto &packet : collected){freePacket(&packet);}
            return -2;
        }
        if (returnValue == SLTOOLARGE)
        {
            std::cerr << "Internal error: Payload length "
                      << (seedLinkPacketInfo ? seedLinkPacketInfo->payloadlength : 0)
                      << " exceeds buffer size " << SL_RECV_BUFFER_SIZE
                      << std::endl;
            continue;
        }
        if (returnValue != SLPACKET || seedLinkPacketInfo == nullptr)
        {
            std::cerr << "Unhandled SEEDLink return value: "
                      << returnValue << std::endl;
            continue;
        }
        // Data!  Anything else - an INFO response say - is not ours to decode.
        if (seedLinkPacketInfo->payloadformat == SLPAYLOAD_MSEED2 ||
            seedLinkPacketInfo->payloadformat == SLPAYLOAD_MSEED3)
        {
            try
            {
                // N.B. I've never seen seedlink return more than
                //      one packet at a time but we're ready for
                //      the possibility.
                auto temporaryPackets = ::miniSEEDBufferToPackets(
                    seedLinkBuffer.data(),
                    static_cast<int> (seedLinkPacketInfo->payloadlength));
                for (auto &packet : temporaryPackets)
                {
                    // The sequence number belongs to the SEEDLink packet, not
                    // the miniSEED record inside it, so it is stamped here.
                    // Holding on to the last one lets a rebuilt connection
                    // resume from this point.
                    packet.sequenceNumber = seedLinkPacketInfo->seqnum;
                    collected.push_back(std::move(packet));
                }
            }
            catch (const std::exception &e)
            {
                std::cerr << "Failed to unpack sl packet payload because "
                          << e.what() << std::endl;
            }
        }
    }
    if (collected.empty()){return 0;}
    // Hand the samples over to the caller.  Copying the struct copies the
    // data pointer, so ownership moves with it and freePackets releases it.
    auto result
        = static_cast<Packet *> (calloc(collected.size(), sizeof(Packet)));
    if (result == nullptr)
    {
        std::cerr << "Failed to allocate packets" << std::endl;
        for (auto &packet : collected){freePacket(&packet);}
        return -1;
    }
    for (size_t i = 0; i < collected.size(); ++i)
    {
        result[i] = collected[i];
    }
    packets->packets = result;
    packets->nPackets = static_cast<int> (collected.size());
    return 0;
}
