package com.oracle.appbundler;

/**
 * Created by haavar on 1/8/14.
 */
public class AbstractKeyValue {
    private String value = null;

    public String getValue() {
        return value;
    }

    public void addText(String value) {
        this.value = value;
    }

    @Override
    public String toString() {
        return value;
    }
}
