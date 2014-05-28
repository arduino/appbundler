package com.oracle.appbundler;

import java.io.File;
import java.util.ArrayList;
import java.util.List;

public class DocumentType {
    public enum Role{Editor, Viewer, Shell, None}

    private String name;
    private File icon;
    private Role role = Role.None;
    private List<DocumentExtension> extensions = new ArrayList<>();
    private List<MimeType> mimeTypes = new ArrayList<>();
    private List<OsType> osTypes = new ArrayList<>();


    public void setName(String name) {
        this.name = name;
    }

    public void setIcon(File icon) {
          this.icon = icon;
    }

    public void setRole(Role role) {
        this.role = role;
    }

    public void addExtension(DocumentExtension extension) {
        extensions.add(extension);
    }

    public void addMimeType(MimeType mimeType) {
        mimeTypes.add(mimeType);
    }

    public void addOsType(OsType osType) {
        osTypes.add(osType);
    }


    public String getName() {
        return name;
    }

    public File getIcon() {
        return icon;
    }

    public Role getRole() {
        return role;
    }

    public List<? extends AbstractKeyValue> getExtensions() {
        return extensions;
    }

    public List<? extends AbstractKeyValue> getMimeTypes() {
        return mimeTypes;
    }

    public List<? extends AbstractKeyValue> getOsTypes() {
        return osTypes;
    }


    public static class DocumentExtension extends AbstractKeyValue  {
    }

    public static class MimeType extends AbstractKeyValue {
    }

    public static class OsType extends AbstractKeyValue {
    }

}
