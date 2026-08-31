package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"os/exec"
	"runtime"
	"strings"

	tea "charm.land/bubbletea/v2"
)

const maxClipboardImageBytes = 10 * 1024 * 1024

type clipboardImage struct {
	Data     string
	Name     string
	MIMEType string
}

var readClipboardImageFn = readClipboardImage

func readClipboardImageCmd() tea.Cmd {
	return func() tea.Msg {
		image, err := readClipboardImageFn()
		return clipboardImageMsg{image: image, err: err}
	}
}

func readClipboardImage() (clipboardImage, error) {
	var data []byte
	var err error

	switch runtime.GOOS {
	case "darwin":
		data, err = darwinClipboardPNG()
	case "linux":
		data, err = linuxClipboardPNG()
	case "windows":
		data, err = windowsClipboardPNG()
	default:
		err = fmt.Errorf("clipboard images are not supported on %s", runtime.GOOS)
	}
	if err != nil {
		return clipboardImage{}, err
	}
	if len(data) == 0 {
		return clipboardImage{}, errors.New("clipboard does not contain an image")
	}
	if len(data) > maxClipboardImageBytes {
		return clipboardImage{}, fmt.Errorf("clipboard image exceeds the %d MB limit", maxClipboardImageBytes/(1024*1024))
	}
	if !bytes.HasPrefix(data, []byte{137, 80, 78, 71, 13, 10, 26, 10}) {
		return clipboardImage{}, errors.New("clipboard image could not be converted to PNG")
	}

	return clipboardImage{
		Data:     base64.StdEncoding.EncodeToString(data),
		Name:     "pasted-image.png",
		MIMEType: "image/png",
	}, nil
}

func darwinClipboardPNG() ([]byte, error) {
	script := `ObjC.import('AppKit'); ObjC.import('Foundation');
var pasteboard = $.NSPasteboard.generalPasteboard;
var data = pasteboard.dataForType($.NSPasteboardTypePNG);
if (!data) {
  var tiff = pasteboard.dataForType($.NSPasteboardTypeTIFF);
  if (tiff) {
    var image = $.NSBitmapImageRep.imageRepWithData(tiff);
    if (image) data = image.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $.NSDictionary.dictionary);
  }
}
if (!data) throw new Error('clipboard does not contain an image');
data.base64EncodedStringWithOptions(0).js;`

	encoded, err := exec.Command("osascript", "-l", "JavaScript", "-e", script).Output()
	if err != nil {
		return nil, commandError("read macOS clipboard", err)
	}
	return base64.StdEncoding.DecodeString(strings.TrimSpace(string(encoded)))
}

func linuxClipboardPNG() ([]byte, error) {
	if path, err := exec.LookPath("wl-paste"); err == nil {
		return exec.Command(path, "--no-newline", "--type", "image/png").Output()
	}
	if path, err := exec.LookPath("xclip"); err == nil {
		return exec.Command(path, "-selection", "clipboard", "-t", "image/png", "-o").Output()
	}
	return nil, errors.New("install wl-paste or xclip to read clipboard images")
}

func windowsClipboardPNG() ([]byte, error) {
	script := `Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing; $image=[Windows.Forms.Clipboard]::GetImage(); if ($null -eq $image) { throw 'clipboard does not contain an image' }; $stream=New-Object IO.MemoryStream; $image.Save($stream,[Drawing.Imaging.ImageFormat]::Png); [Convert]::ToBase64String($stream.ToArray())`
	encoded, err := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script).Output()
	if err != nil {
		return nil, commandError("read Windows clipboard", err)
	}
	return base64.StdEncoding.DecodeString(strings.TrimSpace(string(encoded)))
}

func commandError(action string, err error) error {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		detail := strings.TrimSpace(string(exitErr.Stderr))
		if detail != "" {
			return fmt.Errorf("%s: %s", action, detail)
		}
	}
	return fmt.Errorf("%s: %w", action, err)
}
