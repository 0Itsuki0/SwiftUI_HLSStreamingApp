//
//  PlaylistGenerator.swift
//  HLSDemoApp
//
//  Created by Itsuki on 2025/09/24.
//
// Create Playlist (M3U8) based on the generated segments.
//
/* Sample Playlist
 #EXTM3U
 #EXT-X-TARGETDURATION:3
 #EXT-X-VERSION:7
 #EXT-X-MEDIA-SEQUENCE:0
 #EXT-X-PLAYLIST-TYPE:EVENT
 #EXT-X-INDEPENDENT-SEGMENTS
 #EXT-X-MAP:URI="fileSequence0.mp4"
 #EXTINF:0.70000,
 fileSequence1.m4s
 #EXTINF:2.00000,
 fileSequence2.m4s
 #EXTINF:2.00000,
 fileSequence3.m4s
 #EXTINF:2.00000,
 fileSequence4.m4s
 #EXT-X-ENDLIST
 */

import AVFoundation

nonisolated
enum PlaylistGenerationError: Error {
    case moreThanOneInitialSegmentFound
    case reportNotFoundForSeparableSegment
    case timingTrackingReportNotFound
}


// Extensions for generating event playlist.
//
// An event playlist is specified by the EXT-X-PLAYLIST-TYPE tag with a value of EVENT. It doesn’t initially have an EXT-X-ENDLIST tag, indicating that new media files will be added to the playlist as they become available.
extension Array where Element == Segment {

    // Generate a full m3u8 event playlist. (not used in this demo)
    nonisolated
    func fullEventPlaylist(
        segmentDuration: Int,
        filenamePrefix: String,
    ) throws -> String {
        var previousSegmentInfo: (String, AVAssetSegmentTrackReport)? = nil
        return try partialEventPlaylist(previousSegmentInfo: &previousSegmentInfo, segmentDuration: segmentDuration, filenamePrefix: filenamePrefix, isFinal: true)
    }
    
    
    // Generate partial m3u8 event playlist for only the new segments added.
    //
    // Reason to use this function instead of the one above every single time with the full segments:
    // 1. Playlist entries (segmented files) can not be changed once they are added and we want to avoid any changes that might occur while round
    // 2. On the server side, instead of re-writing the entire playlist, we want to only append the new contents to avoid any possible time gap in re-writing that might cause the client obtaining empty playlist. This can This can be crucial for other clients to view the playlist in real time.
    //
    // the last segment in the array will be appended next round for a more accurate duration calculation if we are not at final round.
    nonisolated
    func partialEventPlaylist(
        previousSegmentInfo: inout (String, AVAssetSegmentTrackReport)?,
        segmentDuration: Int,
        filenamePrefix: String,
        isFinal: Bool
    ) throws -> String {
        var content: String = ""
        
        for segment in self {
            if segment.isInitializationSegment {
                // There is only one initialization segment, and it comes first. Add the initial tags to the index file.
                guard content.isEmpty, previousSegmentInfo == nil else {
                    throw PlaylistGenerationError.moreThanOneInitialSegmentFound
                }
                let fileName = segment.filename(prefix: filenamePrefix)
                
                content = "#EXTM3U\n"
                // individual Media Segments MUST NOT exceed the target duration by more than 0.5 seconds.
                + "#EXT-X-TARGETDURATION:\(segmentDuration)\n"
                + "#EXT-X-VERSION:7\n"
                + "#EXT-X-MEDIA-SEQUENCE:0\n"
                + "#EXT-X-PLAYLIST-TYPE:EVENT\n"
                + "#EXT-X-INDEPENDENT-SEGMENTS\n"
                + "#EXT-X-MAP:URI=\"\(fileName)\"\n"
                
            } else {

                // A separable segment will always include a segment report.
                guard let segmentReport = segment.report else {
                    throw PlaylistGenerationError.reportNotFoundForSeparableSegment
                }
                
                // For each separable segment, calculate the duration of the previous segment and add an entry for that segment to the index file.
                // When the HLS stream will have both audio and video, prefer the video track's timing when calculating the segment duration.
                // Although AVAssetSegmentTrackReport has a duration property, this represents the decode duration.
                // In order to properly calculate the value for #EXTINF, you need the presentation duration.
                // To calculate presentation duration of the previous segment, take the difference between this segment's presentation time stamp
                // and the previous segment's presentation timestamp.
                guard let timingTrackReport = segmentReport.timingTrackReport else {
                    throw PlaylistGenerationError.timingTrackingReportNotFound
                }
                
                if let (previousFilename, previousTimingTrackReport) = previousSegmentInfo {
                    let segmentDuration = timingTrackReport.earliestPresentationTimeStamp - previousTimingTrackReport.earliestPresentationTimeStamp
                    
                    content = content
                        + "#EXTINF:\(String(format: "%1.5f", segmentDuration.seconds)),\t\n"
                        + "\(previousFilename)\n"
                }
                
                // Stash away the current segment to refer back to when you get the next segment.
                previousSegmentInfo = (segment.filename(prefix: filenamePrefix), timingTrackReport)
            }

        }
        
        if !isFinal {
            return content
        }
        
        // Append an entry for the final segment, if there were any segments.
        // Here we use the duration property because there is no time stamp available for the end of the segment.
        if let finalSegmentInfo = previousSegmentInfo {
            let segmentDuration = finalSegmentInfo.1.duration
            content = content
                + "#EXTINF:\(String(format: "%1.5f", segmentDuration.seconds)),\t\n"
                + "\(finalSegmentInfo.0)\n"
        }
        
        // Add the closing tag.
        return content + "#EXT-X-ENDLIST\n"
    }
}


extension AVAssetSegmentReport {
    nonisolated
    var timingTrackReport: AVAssetSegmentTrackReport? {
        return self.trackReports.first(where: { $0.mediaType == .video })
    }
}
