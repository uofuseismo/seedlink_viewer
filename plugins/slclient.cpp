#include <cmath>
#include <iostream>
#include <string>
#include <libslink.h>
#include <boost/property_tree/ptree.hpp>
#include <boost/property_tree/xml_parser.hpp>
#include "slclient.h"

/*
int main()
{
}
*/

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
    const std::string clientVersion{"0.0.1"};
    auto slconn = sl_initslcd(clientName.c_str(),
                              clientVersion.c_str());
    connection->connection = reinterpret_cast<void *> (slconn);
    connection->hasConnection = true;

    const auto address = std::string{options->host}
                       + ":" + std::to_string(options->port);
    if (sl_set_serveraddress(slconn, address.c_str()) != 0)
    {
        std::cerr << "Failed to set seedlink server address to : "
                  << address << std::endl;
        return -1;
    }
    constexpr bool nonBlock{true};
    sl_set_blockingmode(slconn, nonBlock); // don't block thread
    constexpr bool closeConnection{false};
    sl_set_dialupmode(slconn, closeConnection); // keep-alive connection
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
    auto slconn = reinterpret_cast<SLCD *> (connection->connection);
    auto returnCode = sl_ping(slconn, slServerID.data(), slSite.data());
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
            auto slconn = reinterpret_cast<SLCD *> (connection->connection);
            sl_freeslcd(slconn);
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

FFI_PLUGIN_EXPORT intptr_t getPackets(SEEDLinkConnection *connection, Packets *packets)
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
    // Get a handle on the connection 
    auto slconn = reinterpret_cast<SLCD *> (connection->connection);
    // Read as much as we can (or up until the given chunk size)
    for (int k = 0; k < 256; ++k)
    {
        const SLpacketinfo *seedLinkPacketInfo{nullptr};
        std::array<char, SL_RECV_BUFFER_SIZE> seedLinkBuffer;
        auto returnValue = sl_collect(slconn, 
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
