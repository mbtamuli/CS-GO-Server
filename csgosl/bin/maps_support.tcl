#!/bin/sh
# -*- tcl -*-
# The next line is executed by /bin/sh, but not tcl \
exec wish "$0" ${1+"$@"}

proc LoadMapPreview {url map type id} {
    global serverFolder
    set dest [GetWorkshopMapPath "$map"]
    if {"$dest" != ""} {
        set dest "$serverFolder/csgo/maps/$dest/$map.jpg"
        Trace "Trying to load workshop map preview for map $map from $url to $dest"
    } else {
        set dest "$serverFolder/csgo/maps/$map.jpg"
        Trace "Trying to load internal map preview for map $map from $url to $dest"
    }
    Wget $url $dest
    if { ! [file exists $dest] } {
        Trace "Failed to download jpeg map preview for map $map from $url to $dest"
        return 0
    }
    CacheMap "$map" "$type" "$id"
    return 1
}

proc WorkshopMapStillExistsAtSteam {id tmpPath} {
    set htmlFile "$tmpPath/temp.html"
    Trace "Checking if workshop map with $id is still available at Steam..."
    set url "http://steamcommunity.com/sharedfiles/filedetails/?id=$id"
    Wget $url $htmlFile
    if { ! [file exists $htmlFile] } {
        Trace "Failed to download $url"
        return 0
    }
    set fp [open "$htmlFile" r]
    set fileData [read $fp]
    close $fp
    file delete $htmlFile
    set data [split $fileData "\n"]
    foreach line $data {
        if { [string match "*That item does not exist*" $line] } {
            return 0
        }
    }
    return 1
}

proc GetMaps {path allMapsName allMapsMetaName} {
    set maps [list]
    set mapsMeta [dict create]
    global steamConfig
    set validateWorkshopMaps [GetConfigValue $steamConfig validateworkshopmaps]
    Trace "Workshop map validation status : $validateWorkshopMaps"
    if {[file isdirectory "$path/workshop"]} {
        set workshopdirs [glob -nocomplain -tails -type d -path "$path/workshop/" *]
        #workshop maps takes precedence over internal maps
        foreach d $workshopdirs {
            if {[file isdirectory "$path/workshop/$d"]} {
                set m [glob -nocomplain -tails -type f -path "$path/workshop/$d/" *.bsp]
                set m [file rootname $m]
                if { $validateWorkshopMaps && ! [WorkshopMapStillExistsAtSteam "$d" "$path/workshop/$d"] } {
                    Trace "Workshop map $m (with id $d) no longer exists in Steam, disabled by being moved to $path/workshop-DISABLED"
                    if { ! [file isdirectory "$path/workshop-DISABLED" ] } {
                        file mkdir "$path/workshop-DISABLED"
                    }
                    file rename -force "$path/workshop/$d" "$path/workshop-DISABLED/$d"                    
                } elseif {$m ni $maps} {
                        lappend maps $m
                        set mapsMeta [dict set mapsMeta $m [dict create type workshop id $d]]
                }
            }
        }
    }
    if {[file isdirectory "$path"]} {
        set files [glob -nocomplain -tails -type f -path "$path" *.bsp]
        foreach m $files {
            set m [file rootname $m]
            if {$m ni $maps} {
                lappend maps $m
                set mapsMeta [dict set mapsMeta $m [dict create type internal]]
            }
        }
    }
    global $allMapsName
    global $allMapsMetaName
    set $allMapsName [lsort $maps]
    set $allMapsMetaName $mapsMeta
}

proc SetMapsState {maps mapGroup} {
    foreach map $maps {
        global mapState$map
        set mapState$map 0
        if { [lsearch $mapGroup $map] != -1 } {
            set mapState$map 1
        }
    }
}

proc GetMapsState {maps} {
    set mapGroup [list]
    foreach map $maps {
        global mapState$map
        set mapStateValue [set mapState$map]
        if { $mapStateValue == 1 } {
            set mapGroup [lappend mapGroup $map]
        }
    }
    return $mapGroup
}

proc DoImportMapPicture {map from to} {
    set width 320
    set height 256
    image create photo mapButtonImgOrig -file "$from/$map.jpg"
    set w [image width mapButtonImgOrig]
    if { $w >= $width } {
        set q [expr $w / $width]
        image create photo mapButtonImg
        if { $q > 1 } {
            mapButtonImg copy mapButtonImgOrig -subsample $q            
        } else {
            image create photo mapButtonImgTmp
            mapButtonImgTmp copy mapButtonImgOrig -zoom 2
            mapButtonImg copy mapButtonImgTmp -subsample 4
        }
        mapButtonImg write -format jpeg "$to/$map.jpg"
    } else {
        image create photo mapButtonImg
        mapButtonImg copy mapButtonImgOrig -zoom 2
        mapButtonImg write -format jpeg "$to/$map.jpg"
    }
}

proc ImportMapPicture {map from to} {
    Trace "Importing map from $from/$map.jpg to $to/$map.jpg"
    if {[catch {DoImportMapPicture $map $from $to} errMsg]} {
        Trace "Failed importing map $map from $from to $to, using default image ($errMsg)"
        file copy -force [file join $starkit::topdir "no_map_picture.jpg"] "$to/$map.jpg"
    }
}

proc GetMapImageUrl {htmlfile protocol matcherBegin matcherEnd} {
    set fp [open "$htmlfile" r]
    set fileData [read $fp]
    close $fp
    set data [split $fileData "\n"]
    set n 0
    foreach line $data {
        set line [string trimleft $line]
        if { [string first "$matcherBegin" $line] == 0 && [string last "$matcherEnd" $line] > 0} {
            set start [string first $protocol $line ]
            set stop [expr [string last $matcherEnd $line] - 1]
            return [string range $line $start $stop]
        }
        if { [incr n] > 20 } {
            return ""
        }
    }
    return ""
}

#<link rel="image_src" href="http://images.akamai.steamusercontent.com/ugc/884098384874424133/13068CB677948EC551F775C8603445E2CDD14BCC/?interpolation=lanczos-none&output-format=jpeg&output-quality=95&fit=inside|512:*">
#<link rel="image_src" href="https://steamuserimages-a.akamaihd.net/ugc/3281180873728311819/394154653C6BD4B8410C781B94898BDFC01002D2/?interpolation=lanczos-none&output-format=jpeg&output-quality=95&fit=inside%7C512%3A*">
proc LoadMapImageFromWorkshop {url workshopDir id map} {
    set mapDir "$workshopDir/$id"
    set htmlFile "$mapDir/temp.html"
    Wget $url $htmlFile
    if { ! [file exists $htmlFile] } {
        Trace "Failed to download $url"
        return 0
    }
    # First try newer URL
    set matcherBegin "<link rel=\"image_src\" href=\"https://steamuserimages-a.akamaihd.net/"
    set matcherEnd "fit=inside%7C512%3A*\">"
    set imageUrl [GetMapImageUrl $htmlFile "https://" $matcherBegin $matcherEnd]
    if {$imageUrl != ""} {        
        Wget $imageUrl "$mapDir/$map.jpg"
    } else {
        # Fallback to older version, still in use?
        set matcherBegin "<link rel=\"image_src\" href=\"http://images.akamai.steamusercontent.com/"
        set matcherEnd "|512:*\">"
        set imageUrl [GetMapImageUrl $htmlFile "http://" $matcherBegin $matcherEnd]
        if {$imageUrl != ""} {        
            Wget $imageUrl "$mapDir/$map.jpg"
        }        
    }
    file delete $htmlFile
}

proc CacheMap {map type id} {
    global serverFolder
    global installFolder
    set serverMapsDir "$serverFolder/csgo/maps"
    set cachedMapsDir "$installFolder/maps/cached"
    if {"$type" == "internal"} {
        if { [file exists "$serverMapsDir/$map.jpg" ] } {
            ImportMapPicture "$map" "$serverMapsDir" "$installFolder/maps/cached"
        }
    } else {
        set workshopMapsDir "$serverMapsDir/workshop"
        if { ! [file exists "$workshopMapsDir/$id/$map.jpg"]} {
            LoadMapImageFromWorkshop "http://steamcommunity.com/sharedfiles/filedetails/?id=$id" "$workshopMapsDir" "$id" "$map"                    
        }
        if { [file exists "$workshopMapsDir/$id/$map.jpg" ] } {
            ImportMapPicture "$map" "$workshopMapsDir/$id" "$installFolder/maps/cached"
        }
    }
}

proc CacheMaps {maps mapsMeta} {
    global serverFolder
    global installFolder
    set cachedMapsDir "$installFolder/maps/cached"

    if { ! [file isdirectory "$cachedMapsDir" ] } {
        file mkdir "$cachedMapsDir"
    }

    foreach map $maps {
        if { ! [file exists "$installFolder/maps/cached/$map.jpg"] } {
            set meta [dict get $mapsMeta $map]
            set type [dict get $meta type]
            set id ""
            if { [dict exists $meta id] } {
                set id [dict get $meta id]
            }
            CacheMap "$map" "$type" "$id"
        } 
    }
    set cachedMaps [glob -nocomplain -tails -type f -path "$installFolder/maps/cached/" *.jpg]
    foreach m $cachedMaps {
        set m [file rootname $m]
        if {$m ni $maps} {
            Trace "Removing cached image for no longer existing map $m"
            file delete -force $installFolder/maps/cached/$m.jpg
        }
    }
}

proc GetActiveMaps {selectedMapGroup} {
    global mapGroupsMapper
    if { [dict exists $mapGroupsMapper $selectedMapGroup] } {
        return [dict get $mapGroupsMapper $selectedMapGroup]
    } else {
        global allMaps
        return $allMaps
    }    
}

proc GetFirstMapInMapGroup {selectedMapGroup} {
    global mapGroupsMapper
    global allMaps
    if { [dict exists $mapGroupsMapper $selectedMapGroup] } {
        set mapGroups [dict get $mapGroupsMapper $selectedMapGroup]
        if { [llength $mapGroups] > 0} {
            return [lindex $mapGroups 0]  
        } else {
            return [lindex $allMaps 0]  
        }
    } else {
        return [lindex $allMaps 0]  
    }    
}

proc GetWorkshopMapPath { thisMap } {
    global allMapsMeta
    if { [dict exists $allMapsMeta $thisMap] } {
        set mapMeta [dict get $allMapsMeta $thisMap]
        set mapType [dict get $mapMeta type]
        if { $mapType == "workshop" } {
            set id [dict get $mapMeta id]
            return "workshop/$id"
        }
        
    }
    return ""
}