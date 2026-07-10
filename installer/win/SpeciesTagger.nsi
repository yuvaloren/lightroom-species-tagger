; SpeciesTagger.nsi — Windows one-click installer for the Species Tagger
; Lightroom Classic plugin.
;
; Installs SpeciesTagger.lrplugin into the CURRENT USER's Lightroom auto-load
; folder — %APPDATA%\Adobe\Lightroom\Modules — so Lightroom Classic picks it up
; on next launch with ZERO Plug-in Manager steps. Per-user install: no UAC
; prompt, no admin rights. Writes a normal HKCU uninstall entry (Settings ▸
; Apps) and an Uninstall.exe inside the plugin folder.
;
; Compiled CROSS-PLATFORM by makensis (Homebrew on macOS) from
; scripts/build-win-installer.sh, which supplies:
;   /DVERSION=<x.y.z[-suffix]>  /DVIVERSION=<x.y.z.0>
;   /DPAYLOAD=<staged SpeciesTagger.lrplugin dir>   (extracted from the -win zip
;                                                    — single packaging truth)
;   /DOUTFILE=<output path>

Unicode true
!include "MUI2.nsh"
!include "FileFunc.nsh"

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
VIAddVersionKey "LegalCopyright" "© Yuval Oren"

; ---- pages -------------------------------------------------------------------
!define MUI_WELCOMEPAGE_TITLE "Species Tagger for Lightroom Classic"
!define MUI_WELCOMEPAGE_TEXT "This installs the Species Tagger plug-in for the current user. No administrator rights are needed, and there is nothing to configure — Lightroom Classic finds the plug-in automatically the next time it starts.$\r$\n$\r$\nYou need Adobe Lightroom Classic and Google Chrome installed to use it.$\r$\n$\r$\nIf you previously installed Species Tagger by hand through the Plug-in Manager, remove that old entry afterwards (File > Plug-in Manager > Remove) so it isn't listed twice."
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES

!define MUI_FINISHPAGE_TITLE "Species Tagger is installed"
!define MUI_FINISHPAGE_TEXT "Where to find it:$\r$\n$\r$\nSelect photos in the Library, then choose$\r$\nLibrary  >  Plug-in Extras  >  Identify and Tag Species$\r$\n$\r$\nA Chrome window opens with Google Lens results — highlight the species name and press Tag.$\r$\n$\r$\nIf Lightroom Classic was open during this install, restart it so it picks the plug-in up."
!define MUI_FINISHPAGE_SHOWREADME "${WIKI_URL}"
!define MUI_FINISHPAGE_SHOWREADME_TEXT "Open the quick-start guide"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"

; ---- install -------------------------------------------------------------------
Section "Species Tagger"
	; Clean upgrade: replace any previous copy wholesale so removed files
	; never linger inside the plugin folder.
	RMDir /r "$INSTDIR"
	SetOutPath "$INSTDIR"
	File /r "${PAYLOAD}\*.*"

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
