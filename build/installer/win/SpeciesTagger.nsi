; SpeciesTagger.nsi -- Windows one-click installer for the Species Tagger
; Lightroom Classic plugin.
;
; Installs SpeciesTagger.lrplugin into the CURRENT USER's Lightroom auto-load
; folder -- %APPDATA%\Adobe\Lightroom\Modules -- so Lightroom Classic picks it up
; on next launch with ZERO Plug-in Manager steps. Per-user install: no UAC
; prompt, no admin rights. Writes a normal HKCU uninstall entry (Settings >
; Apps) and an Uninstall.exe inside the plugin folder.
;
; Compiled CROSS-PLATFORM by makensis (Homebrew on macOS) from
; build/build-win-installer.sh, which supplies:
;   /DVERSION=<x.y.z[-suffix]>  /DVIVERSION=<x.y.z.0>
;   /DPAYLOAD=<staged SpeciesTagger.lrplugin dir>   (extracted from the -win zip
;                                                    -- single packaging truth)
;   /DOUTFILE=<output path>

; ASCII-only file + Unicode false: Homebrew makensis on macOS crashes
; (std::bad_alloc, NSIS bug #1165) on ANY Unicode-target build and rejects
; UTF-8 script input outright ("Bad text encoding"). All user-visible strings
; are plain ASCII, so an ANSI installer loses nothing here. TODO: flip to
; `Unicode true` when a fixed makensis ships (test: makensis a script without
; `Unicode false` -- if it stops crashing, the bug is gone). Edge case while
; ANSI: non-Latin Windows usernames outside the system codepage could break
; the install path -- a known ANSI-installer edge case.
Unicode false
!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "x64.nsh"

Name "Species Tagger for Lightroom Classic"
OutFile "${OUTFILE}"
RequestExecutionLevel user
InstallDir "$APPDATA\Adobe\Lightroom\Modules\SpeciesTagger.lrplugin"
SetCompressor /SOLID lzma

!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\SpeciesTagger"
!define WIKI_URL "https://github.com/yuvaloren/lightroom-species-tagger/wiki"

VIProductVersion "${VIVERSION}"
VIAddVersionKey "ProductName" "Species Tagger for Lightroom Classic"
VIAddVersionKey "FileDescription" "Species Tagger installer"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "(c) Yuval Oren"

; ---- pages -------------------------------------------------------------------
!define MUI_WELCOMEPAGE_TITLE "Species Tagger for Lightroom Classic"
!define MUI_WELCOMEPAGE_TEXT "This installs the Species Tagger plug-in for the current user. No administrator rights are needed, and there is nothing to configure -- Lightroom Classic finds the plug-in automatically the next time it starts.$\r$\n$\r$\nYou need Adobe Lightroom Classic and Google Chrome installed to use it.$\r$\n$\r$\nIf you previously installed Species Tagger by hand through the Plug-in Manager, remove that old entry afterwards (File > Plug-in Manager > Remove) so it isn't listed twice."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_TITLE "Species Tagger is installed"
!define MUI_FINISHPAGE_TEXT "Where to find it:$\r$\n$\r$\nSelect photos in the Library, then choose$\r$\nFile  >  Plug-in Extras  >  Identify and Tag Species$\r$\n$\r$\nA Chrome window opens with Google Lens results -- highlight the species name and press Tag.$\r$\n$\r$\nIf Lightroom Classic was open during this install, restart it so it picks the plug-in up."
!define MUI_FINISHPAGE_SHOWREADME "${WIKI_URL}"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Open the quick-start guide"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ---- install -------------------------------------------------------------------
Section "Species Tagger"
	; Clean upgrade: replace any previous copy wholesale so removed files
	; never linger inside the plugin folder (a <=0.3.x install carried a
	; ~90 MB bundled Node runtime under node/ + lens/ -- this wipes it).
	RMDir /r "$INSTDIR"
	SetOutPath "$INSTDIR"
	; Install only the NATIVE Windows helper. The payload carries win-x64 AND
	; win-arm64; resolveHelper (Http.lua) runs the first that EXISTS, x64
	; first. Pruning here gives ARM machines the native arm64 binary (no x64
	; on disk -> the candidate loop falls through), while zip installs simply
	; run win-x64 everywhere (emulated on Windows-on-ARM).
	${If} ${IsNativeARM64}
		File /r /x "win-x64" "${PAYLOAD}\*.*"
	${Else}
		File /r /x "win-arm64" "${PAYLOAD}\*.*"
	${EndIf}

	WriteUninstaller "$INSTDIR\Uninstall.exe"
	WriteRegStr HKCU "${UNINST_KEY}" "DisplayName" "Species Tagger for Lightroom Classic"
	WriteRegStr HKCU "${UNINST_KEY}" "DisplayVersion" "${VERSION}"
	WriteRegStr HKCU "${UNINST_KEY}" "Publisher" "Yuval Oren"
	WriteRegStr HKCU "${UNINST_KEY}" "URLInfoAbout" "${WIKI_URL}"
	WriteRegStr HKCU "${UNINST_KEY}" "UninstallString" '"$INSTDIR\Uninstall.exe"'
	WriteRegStr HKCU "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
	WriteRegDWORD HKCU "${UNINST_KEY}" "NoModify" 1
	WriteRegDWORD HKCU "${UNINST_KEY}" "NoRepair" 1

	; EstimatedSize (KB) for the Apps list.
	${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
	WriteRegDWORD HKCU "${UNINST_KEY}" "EstimatedSize" $0
SectionEnd

; ---- uninstall ------------------------------------------------------------------
Section "Uninstall"
	RMDir /r "$INSTDIR"
	DeleteRegKey HKCU "${UNINST_KEY}"
SectionEnd
